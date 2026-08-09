# ─────────────────────────────────────────────────────────────────────────────
#  VARIANT: ha
#
#  The same architecture as variants/solo, at a different operating point. Read
#  docs/variant-delta.md for the exact diff; this header is the intent behind it.
#
#  What changes, and what each change actually buys:
#    3 control planes (2 + 1 across two locations) — losing one no longer stops
#      scheduling, ArgoCD sync and every kubectl. You still operate etcd.
#    3 general agents instead of 2 — enough capacity to EMPTY one, which is what
#      makes a real drain possible. On 2026-08-05 the two-node variant cordoned a
#      node for 2.5 hours with 8 pods Pending because there was nowhere to put them.
#    system_upgrade_use_drain = true — reversing the solo mitigation, because the
#      headroom above is the precondition that was missing.
#    A redundant NAT router — in solo it is a single point of failure that takes
#      SSH and the kube-API path with it.
#    A cluster autoscaler with room to grow instead of a single spare node.
#
#  What it does NOT buy, stated here so nobody has to discover it:
#    - No managed control-plane SLA. There is nobody to page.
#    - No node auto-repair. A NotReady node stays NotReady until a human acts.
#    - Hetzner has no availability zones inside a location, so "multi-location"
#      here means multi-DATACENTRE — a different, larger latency domain than the
#      zones EKS/GKE/AKS spread across. That is a trade, not an upgrade.
#  docs/managed-k8s-parity.md has the full accounting.
#
#  NEVER APPLIED TO PRODUCTION by its authors. Its failure modes are proven only
#  as far as the green-field build in the project's M4 phase proved them, and the
#  README says which those are.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  # kured ships tolerations for control-plane/master only; without the egress toleration it
  # never runs on the egress node, that node never reboots, and MicroOS transactional-update
  # snapshots fill its 40GB disk (DiskPressure since 2026-06-05, follow-up 07).
  # Strategic merge REPLACES the whole tolerations list (no patchMergeKey on tolerations),
  # so repeated applies are idempotent — never switch this to a json-patch "add".
  # NB: re-apply after a kured_version bump (the upstream manifest resets tolerations).
  kured_tolerations_patch = jsonencode({
    spec = {
      template = {
        spec = {
          tolerations = [
            { effect = "NoSchedule", key = "node-role.kubernetes.io/control-plane" },
            { effect = "NoSchedule", key = "node-role.kubernetes.io/master" },
            { effect = "NoSchedule", key = "node.kubernetes.io/role", operator = "Equal", value = "egress" },
            # Dedicated CI pool (agent-ci) is tainted NoSchedule; without this kured never
            # reboots it and MicroOS snapshots fill its 40GB disk (same failure mode as egress).
            { effect = "NoSchedule", key = "node.kubernetes.io/role", operator = "Equal", value = "ci" },
          ]
        }
      }
    }
  })

  # kured's reboot window and drain behaviour. Kept as a local so the marker template can
  # embed a fingerprint of it: changing kured_options re-renders the upstream kured
  # manifest, which drops the tolerations patched in above, and before the fingerprint
  # existed that did NOT re-trigger the patch hook. On 2026-06-13 the egress toleration
  # disappeared exactly this way, and nothing reported it.
  kured_options = {
    "drain-timeout" = "5m"
    "force-reboot"  = "true"
    "lock-ttl"      = "30m"
    "start-time"    = "03:00"
    "end-time"      = "05:00"
    "time-zone"     = var.cluster_timezone
  }

  # The small agent node hosts zero Longhorn replicas, but kept flipping Schedulable
  # around Longhorn's 25% hard stop and polluted capacity monitoring with the noise.
  # Turning scheduling off for it fixes that.
  #
  # Longhorn does not reconcile spec.allowScheduling back, so a one-off patch would
  # normally be enough. A node REBUILD is the exception: the manager recreates the Node
  # custom resource with allowScheduling=true and a NEW random name suffix, so any
  # hardcoded node name silently stops matching. Hence a loop over a name pattern,
  # re-applied idempotently on every kustomize deploy.
  longhorn_small_no_sched_cmd = "for n in $(kubectl --namespace longhorn-system get nodes.longhorn.io -o name | grep k3s-agent-small-); do kubectl --namespace longhorn-system patch $n --type=merge -p '{\"spec\":{\"allowScheduling\":false}}'; done"

  # Two StorageClasses both mark themselves default: the CSI class from the module
  # (replicated, survives node loss — the intended default) and local-path from the k3s
  # local-storage addon (node-local, gone when the node dies). Two defaults is not a
  # tie-break, it is ambiguity: a PVC that omits storageClassName gets whichever the API
  # server picks. On 2026-07-03 that put a production Postgres on node-local storage.
  #
  # This command turns local-path's default annotation off, which is what the
  # enable_local_storage comment further down always claimed was true. `|| true` so a
  # transient kubectl error never fails the whole kustomize deploy.
  #
  # It is repair, not prevention: k3s's addon deploy controller re-applies local-storage
  # on every k3s START, so the annotation comes back after any restart and this only
  # fixes it at apply time. storageclass.tf declares the same annotation as Terraform
  # state so `terraform plan` at least reports the drift. Fixing it durably would mean
  # --disable local-storage plus a replacement provisioner; local-path is CI-critical
  # here, so that trade was declined deliberately.
  storageclass_default_fix_cmd = "kubectl patch storageclass local-path --type=merge -p '{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"false\"}}}' || true"

  # Stop k3s from owning local-path-provisioner.
  #
  # k3s re-applies its packaged local-storage manifest on every START — not every version
  # upgrade, every start — which resets storageclass.kubernetes.io/is-default-class to
  # "true" and leaves the cluster with two default StorageClasses. Kubernetes tolerates
  # that (it uses the most recently created one) but it means which kind of volume a
  # class-less PVC gets depends on object creation order, and it means `terraform plan` is
  # dirty after every reboot. A plan that is never clean is one people stop reading, which
  # is how the kured tolerations stayed lost for three days.
  #
  # A .skip file makes the deploy controller ignore the manifest. Verified in k3s source
  # (pkg/deploy/controller.go): a skipped file is `continue`, nothing more — the already
  # deployed objects are untouched. Contrast --disable, which calls w.delete() and applies
  # an EMPTY owned set, i.e. removes the StorageClass and the provisioner. That is fine on
  # a cluster that does not have workloads on local-path, and not fine here.
  #
  # k3s' own maintainers recommend exactly this shape of fix (k3s-io/k3s#4083: "provide
  # your own copy of the local-storage manifest"); extra-manifests/local-path-provisioner
  # .yaml.tpl is that copy, generated by scripts/vendor-local-path.sh.
  #
  # Placed in TWO places on purpose, because they cover different nodes:
  #   - postinstall_exec, below: every new or rebuilt node, before it can reset anything.
  #   - extra_kustomize_deployment_commands: the nodes already running, which never re-run
  #     cloud-init. Those commands run AFTER `kubectl apply -k`, so the vendored manifest is
  #     in place before k3s is told to stop managing its own.
  # Guarded on the directory existing, since agents have no manifests directory.
  local_storage_skip_cmd = "test -d /var/lib/rancher/k3s/server/manifests && touch /var/lib/rancher/k3s/server/manifests/local-storage.yaml.skip || true"

  # ── Inputs that re-trigger the UPSTREAM kustomization ──────────────────────
  # kube-hetzner's own terraform_data.kustomization (module init.tf:264-303) is replaced
  # whenever any of these changes. Replacing it re-applies the vanilla kured manifest,
  # which WIPES the toleration patch above — while our patch hook (kustomization_user_deploy)
  # re-runs only when the marker template changes. So the marker must carry a fingerprint of
  # exactly these values, or the patch is lost silently.
  #
  # "Silently" is not theoretical. On 2026-08-05, PR #4 pinned cert-manager and traefik.
  # Both sit in the module's `versions` trigger; neither was in the old fingerprint, which
  # covered only kured_options and the storageclass command. The apply reported success and
  # kured lost its egress and CI tolerations. Found on 2026-08-08 by counting kured pods:
  # 3 of 5 nodes. Those two nodes had stopped rebooting for MicroOS updates entirely.
  #
  # KEEP IN SYNC: adding any module input that appears in the module's kustomization trigger
  # set WITHOUT adding it here re-opens exactly this failure, and it fails silent.
  hetzner_ccm_version  = "v1.22.0"
  hetzner_csi_version  = "v2.22.0"
  kured_version        = "1.21.0"
  cert_manager_version = "v1.20.3"
  traefik_version      = "41.0.0"
  cilium_merge_values  = <<-EOT
encryption:
  enabled: true
  type: wireguard
  EOT
  # HCLOUD_LOAD_BALANCERS_LOCATION must equal load_balancer_location below. If they
  # disagree, the CCM provisions Service-type LoadBalancers in a different datacentre from
  # the nodes they front, and every request pays a cross-site hop that nothing reports.
  hetzner_ccm_merge_values = <<-EOT
env:
  HCLOUD_LOAD_BALANCERS_USE_PRIVATE_IP:
    value: "true"
  HCLOUD_LOAD_BALANCERS_DISABLE_PRIVATE_INGRESS:
    value: "true"
  HCLOUD_LOAD_BALANCERS_LOCATION:
    value: "${var.primary_location}"
  EOT
  longhorn_merge_values    = <<-EOT
defaultSettings:
  defaultDataLocality: best-effort
  replicaSoftAntiAffinity: true
  EOT
  traefik_merge_values     = <<-EOT
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: traefik
  EOT

  # k3s auto-upgrades ran in no window at all: system-upgrade-controller created upgrade
  # jobs whenever it liked, including mid-workday. With system_upgrade_use_drain = false
  # and only two schedulable nodes, an upgrade cordons a node for as long as it takes —
  # on 2026-08-05 that was 2.5 hours with 8 pods Pending. Windowing does not fix the
  # capacity problem (that needs a third worker, see the V2 variant); it moves the
  # disruption to a time when nobody is looking at it.
  #
  # Deliberately 01:00-03:00, ending where kured's reboot window starts (kured_options
  # above, 03:00-05:00). Overlapping them risks system-upgrade-controller cordoning a
  # node while kured wants to reboot that same node. Upgrade first, reboot after.
  system_upgrade_schedule_window = {
    days      = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    startTime = "01:00"
    endTime   = "03:00"
    timeZone  = var.cluster_timezone
  }

  # Pin the channel to the minor version already running (measured 2026-08-08: every node
  # on v1.33.13+k3s2). This is a no-op today — the module's own default is "v1.33" — and
  # that is exactly why it is worth writing down: the value is currently INHERITED, so a
  # module bump that changes the default would move this cluster a minor version with no
  # diff here to show it. Naming it makes that impossible. Patch releases within v1.33
  # still arrive automatically, which is the intended CVE cadence.
  initial_k3s_channel = "v1.33"

  # Kubernetes API audit logging. Nothing recorded who called the API before this: a
  # managed control plane ships audit logs by default, this one shipped none at all
  # (M1 parity row 3.8). The mechanism existed in kube-hetzner 2.19.2 all along and was
  # simply unset.
  #
  # Rule order matters — FIRST match wins. Noise is dropped before anything else, so the
  # volume stays sane on a 40GB control-plane disk; then secrets get an explicit
  # Metadata rule so access is recorded WITHOUT ever writing secret values to disk.
  #
  # Deliberately never RequestResponse, and never Request, anywhere. Both would write
  # request bodies into /var/log/k3s-audit — which for a Secret write means the secret
  # itself, in cleartext, on the node. Metadata answers who/what/when, which is the
  # question an audit log exists to answer.
  k3s_audit_policy = <<-EOT
    apiVersion: audit.k8s.io/v1
    kind: Policy
    omitStages:
      - RequestReceived
    rules:
      # 1. Health and discovery endpoints: constant, zero forensic value.
      - level: None
        nonResourceURLs:
          - /healthz*
          - /readyz*
          - /livez*
          - /version
          - /metrics
          - /openapi*
          - /apis
          - /api
      # 2. Control-plane components reading their own state. This is the bulk of the
      #    traffic and none of it is interesting.
      - level: None
        users:
          - system:kube-scheduler
          - system:kube-controller-manager
          - system:apiserver
          - system:kube-proxy
        verbs: ["get", "list", "watch"]
      - level: None
        userGroups: ["system:nodes"]
        verbs: ["get", "list", "watch"]
      # 3. Secrets and configmaps: WHO touched them, never WHAT they contain.
      - level: Metadata
        resources:
          - group: ""
            resources: ["secrets", "configmaps"]
      # 4. Everything that changes cluster state.
      - level: Metadata
        verbs: ["create", "update", "patch", "delete", "deletecollection"]
      # 5. Everything else.
      - level: Metadata
  EOT

  # max_nodes is a COST CEILING, not a capacity wish. min_nodes = 0 means the idle bill is
  # unchanged, but an autoscaler with no upper bound has an unbounded monthly cost, and
  # "it only scales when it needs to" is not a budget.
  #
  # The arithmetic, from measured Hetzner prices (see docs/managed-k8s-parity.md):
  # this variant idles at roughly 1.40x the solo variant. A cx33 is about EUR 10.27/month
  # gross, so every point of max_nodes adds up to 0.13x. Three is 1.81x worst case. The
  # project's own stop condition is 2.5x, which is reached at max_nodes = 8 — so eight is
  # a hard ceiling with a reason behind it, not a round number.
  #
  # Raise it only together with the budget line it consumes.
  autoscaler_nodepools = [
    {
      name        = "autoscaled"
      server_type = "cx33"
      location    = var.primary_location
      min_nodes   = 0
      max_nodes   = 3
      labels = {
        "node.kubernetes.io/role" = "autoscaled"
      }
    }
  ]

  kustomization_trigger_fingerprint = sha1(jsonencode({
    kured_options            = local.kured_options
    hetzner_ccm_version      = local.hetzner_ccm_version
    hetzner_csi_version      = local.hetzner_csi_version
    kured_version            = local.kured_version
    cert_manager_version     = local.cert_manager_version
    traefik_version          = local.traefik_version
    cilium_merge_values      = local.cilium_merge_values
    hetzner_ccm_merge_values = local.hetzner_ccm_merge_values
    longhorn_merge_values    = local.longhorn_merge_values
    traefik_merge_values     = local.traefik_merge_values
    # Added with the inputs themselves, per the KEEP IN SYNC note above:
    # initial_k3s_channel is in the module's "versions" trigger and
    # system_upgrade_schedule_window is a trigger key in its own right.
    initial_k3s_channel            = local.initial_k3s_channel
    system_upgrade_schedule_window = local.system_upgrade_schedule_window
    # KEEP IN SYNC caught this one empirically: adding autoscaler_nodepools replaces the
    # module's terraform_data.kustomization (the autoscaler manifest is part of it), which
    # re-applies the vanilla kured manifest and wipes the toleration patch. Without this
    # line the plan showed the wipe and NOT the repair — the silent regression of
    # 2026-08-05, exactly. The plan is what caught it; the assumption did not.
    autoscaler_nodepools = local.autoscaler_nodepools
  }))
}

module "kube-hetzner" {
  providers = {
    hcloud = hcloud
  }
  hcloud_token   = var.hcloud_token
  robot_user     = var.robot_user
  robot_password = var.robot_password
  # Rotated 2026-06-10 — see the notes on variable "k3s_token" in variables.tf.
  k3s_token = var.k3s_token

  source = "kube-hetzner/kube-hetzner/hcloud"

  # THIS PIN IS IMMUTABLE, and not for the reason people usually assume.
  #
  # "A module pinned to a git tag is pinned to something mutable" is true for a git
  # source and false for a registry source, and the difference is invisible in this file.
  # The registry resolved this version to a commit at publish time and hands Terraform
  # that commit, never the tag:
  #
  #   curl -sSI https://registry.terraform.io/v1/modules/kube-hetzner/kube-hetzner/hcloud/2.19.2/download
  #   x-terraform-get: git::https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner
  #                    ?ref=08e59a31197ce8a24d80805e5062ee3ed8ec024d
  #
  # So force-moving the upstream v2.19.2 tag would not change a byte of what gets
  # downloaded here. Verified further: the registry tarball and a fresh clone of that
  # commit are byte-identical across every file. Rewriting this as a git source with an
  # explicit ?ref=<sha> would buy no immutability, cost a full clone on every init, and
  # move the record of the correct SHA from the registry into a comment we maintain.
  #
  # What IS still possible: the module owner deleting and republishing version 2.19.2
  # against a different commit. The SHA above is what to compare against — the curl
  # command is the check, and it belongs in CI.
  #
  # Terraform does not lock modules the way it locks providers, so the exact version
  # below is the only thing holding this in place. Two competing constraints fix it:
  #  - 2.20.0 REMOVED assignee_type from the NAT-router hcloud_primary_ip resources, which
  #    provider 1.60.1 (our committed lock) still REQUIRES -> "Missing required argument".
  #  - 2.19.3 ADDED `trimspace(var.ssh_public_key)`; our state holds the key WITH a trailing
  #    newline (Hetzner preserves it), so trimspace creates a phantom hcloud_ssh_key diff that
  #    cascades into rebuilding the NAT router. 2.19.2 still passes the key untrimmed (matches
  #    state) AND still has assignee_type -> clean plan, no spurious replacements.
  version = "2.19.2"

  # pathexpand so "~/..." works; only the PUBLIC half is ever read here. See
  # ssh_private_key below for why the private half deliberately is not passed.
  ssh_public_key = file(pathexpand(var.ssh_public_key_path))

  # DELIBERATELY null. Give this a value and the module stores the private key as a
  # resource ATTRIBUTE (ssh_sensitive_resource.kubeconfig), not merely inside a
  # connection block — so it is written into the Terraform state in cleartext. A
  # security audit on 2026-08-05 found it there twice, on a key with no passphrase.
  #
  # That makes the state credential equivalent to root on every node: one leaked state
  # access key, one GET, and you have the key. A VPN-only firewall is not a second
  # factor against that, because the same state file also contains the VPN auth key.
  #
  # With null the module falls back to the SSH agent (it sets ssh_agent_identity from
  # the public key). CONSEQUENCE: every terraform run that executes a provisioner needs
  # a running agent with the key loaded:
  #   eval "$(ssh-agent -s)" && ssh-add <private half of var.ssh_public_key_path>
  # This is the module's intended workflow, and it is the first step in README.md.
  #
  # Note what this does and does not fix: it keeps the key out of FUTURE state versions.
  # Versions already written still contain it until they age out — which is one more
  # reason the state bucket needs versioning with a bounded noncurrent retention (90
  # days here, set 2026-08-05) rather than versioning kept forever.
  ssh_private_key = null

  # Named explicitly rather than inherited. Set this to something distinct: this variant
  # is the one people run alongside another cluster, and two projects both containing a
  # cluster called "k3s" produce two identical sets of resource names.
  #
  # Not part of the kustomization trigger set — verified against the module: cluster_name
  # feeds only a local backup filename, none of the helm values locals.
  cluster_name = var.cluster_name

  network_region = "eu-central"

  hetzner_ccm_version = local.hetzner_ccm_version
  # v2.9.0 -> v2.22.0 after an incident on 2026-07-10: the old CSI driver REFORMATTED a
  # production database volume during a node failover. The mechanism is worth knowing
  # because it is silent and total — the driver ran its blkid check before the device
  # path existed, read the absence as "unformatted", and ran mke2fs the moment the device
  # appeared. Upstream fixed it in v2.21.2 ("device needs to be ready on node publish");
  # v2.22.0 is the release pinned here. Do not roll this back to reach an older module
  # version: an empty, healthy-looking volume is the failure mode.
  hetzner_csi_version = local.hetzner_csi_version
  # Pin to the running version. kured tags carry no "v" prefix and the module builds the
  # manifest URL as kured-<ver>-combined.yaml (>=1.20.0); the old "v1.15.1" produced a
  # nonexistent asset URL that broke `kubectl apply -k`. Matches the live DaemonSet exactly.
  kured_version = local.kured_version

  # Prevent a stuck node drain from wedging a node — and starving storage and CI with
  # it — forever. Time-box the drain, reboot anyway, and let stale locks expire, so OS
  # auto-upgrades self-heal instead of deadlocking. (Since 2026-06-13 the database
  # PodDisruptionBudgets allow maxUnavailable=1 and drains normally succeed on their own;
  # force-reboot stays as the safety net, not as the usual path.)
  #
  # The reboot window comes from an audit on 2026-06-12. kured was allowed to reboot
  # 24/7 and did, at arbitrary times — which is what the "random connectivity issues"
  # nobody could reproduce actually were. Reboots are now confined to a night window.
  # reboot-days stays at its default of every day on purpose: restrict the days too and
  # a MicroOS update can sit queued for most of a week.
  # The values live in locals above; see the note there for why.
  kured_options = local.kured_options

  # The module exposes no kured-tolerations variable, so patch the DaemonSet after the
  # kustomize deploy. The hook resource (kustomization_user_deploy) only exists when
  # extra-manifests/ holds at least one template — see extra-manifests/kured-patch-marker
  # .yaml.tpl, which also embeds the patch so changes re-trigger the deploy.
  extra_kustomize_deployment_commands = "kubectl -n kube-system patch daemonset kured --type=strategic -p '${local.kured_tolerations_patch}' && ${local.longhorn_small_no_sched_cmd} && ${local.storageclass_default_fix_cmd} && ${local.local_storage_skip_cmd}"
  extra_kustomize_parameters = {
    kured_tolerations_patch = local.kured_tolerations_patch
    longhorn_small_no_sched = local.longhorn_small_no_sched_cmd
    # Fingerprint: changing kured_options re-renders the upstream kured manifest and
    # wipes the tolerations patch. Baking the fingerprint into the marker template makes
    # the same apply re-trigger the patch hook, so the two move together.
    kured_options_fingerprint = sha1(jsonencode(local.kured_options))
    # Same idea for the storageclass patch command: putting it in the marker template
    # means editing it (or adding it for the first time) re-triggers the deploy hook.
    storageclass_default_fix = local.storageclass_default_fix_cmd
    # See local.kustomization_trigger_fingerprint: this is what makes the patch hook
    # re-run whenever the module re-applies the upstream manifests.
    kustomization_trigger_fingerprint = local.kustomization_trigger_fingerprint
  }

  # Three control planes, split 2 + 1 across two locations.
  #
  # WHY THREE AND NOT TWO. etcd needs a strict majority to accept writes. Two members
  # have a majority of two, so losing either one stops the API — two control planes are
  # strictly worse than one, because there are twice as many things that can fail and no
  # tolerance for either. Three tolerates one loss. Four tolerates one loss and costs more.
  #
  # WHY 2 + 1 AND NOT 1 + 1 + 1. With one member per location, losing the location holding
  # a member costs you a third of the quorum and you survive. That sounds better, and for
  # etcd it is worse: every write must be acknowledged by a majority, so with members
  # spread evenly across three sites every single write crosses the network twice. With
  # 2 + 1 the majority can be formed entirely inside the primary location, so the common
  # case never leaves it — and losing the primary location still costs you the cluster,
  # which is the honest trade being made here.
  #
  # WHAT THIS DOES NOT SURVIVE: losing var.primary_location. Two of three members live
  # there. If surviving the loss of an entire datacentre is the requirement, this topology
  # is the wrong one and no amount of tuning fixes it — that needs 1 + 1 + 1 and an
  # acceptance of per-write cross-site latency.
  #
  # The third member gets its OWN placement group. A spread placement group guarantees
  # different physical hosts within a location; across locations the guarantee is already
  # implied and Hetzner has no reason to honour one group in two datacentres. Sharing a
  # group would be, at best, a request that means nothing.
  control_plane_nodepools = [
    {
      name        = "control-plane-1",
      server_type = "cx23",
      location    = var.primary_location,
      labels      = [],
      taints      = [],
      count       = 1

      disable_ipv4 = true
      disable_ipv6 = true
    },
    {
      name        = "control-plane-2",
      server_type = "cx23",
      location    = var.primary_location,
      labels      = [],
      taints      = [],
      count       = 1

      disable_ipv4 = true
      disable_ipv6 = true
    },
    {
      name        = "control-plane-3",
      server_type = "cx23",
      location    = var.secondary_location,
      labels      = [],
      taints      = [],
      count       = 1

      # Its own spread group — see the note above.
      placement_group = "secondary"

      disable_ipv4 = true
      disable_ipv6 = true
    }
  ]

  agent_nodepools = [
    {
      name = "agent-small"
      # Resized cx23(4GB)→cx33(8GB) 2026-06-13: the DB node (6 postgres + keycloak-pg +
      # redis, all 7 hcloud-volumes attach here) was memory-bound at ~85%. cx33 doubles RAM.
      server_type = "cx33",
      location    = var.primary_location,
      labels      = [],
      taints      = [],
      count       = 1
      # subnet_ip_range = "10.0.0.0/16"  # Optional: override default subnet range
      # swap_size   = "2G" # remember to add the suffix, examples: 512M, 1G
      # zram_size   = "2G" # remember to add the suffix, examples: 512M, 1G

      # CPU+disk reservation only: small-pkb (4GB) is memory-tight with the platform
      # databases, so reserving memory here would evict them. CPU reservation +
      # enforce-node-allocatable=pods is what actually prevents kubelet starvation —
      # the root cause (incident-large-dqa-notready 2026-06-13) was CPU/IO, not memory.
      kubelet_args = [
        "kube-reserved=cpu=100m,ephemeral-storage=1Gi",
        "system-reserved=cpu=150m,ephemeral-storage=1Gi",
        "eviction-hard=memory.available<100Mi,nodefs.available<10%,imagefs.available<10%",
        "enforce-node-allocatable=pods",
      ]

      # Fine-grained control over placement groups (nodes in the same group are spread over different physical servers, 10 nodes per placement group max):
      # placement_group = "default"

      disable_ipv4 = true
      disable_ipv6 = true

    },
    {
      name        = "agent-large",
      server_type = "cx33",
      location    = var.primary_location,
      labels      = [],
      taints      = [],
      count       = 1

      # CPU+disk+modest-memory reservation so platform pods can never starve the kubelet.
      # large (8GB) has the headroom for a small memory reserve; small does not.
      kubelet_args = [
        "kube-reserved=cpu=100m,memory=256Mi,ephemeral-storage=2Gi",
        "system-reserved=cpu=200m,memory=256Mi,ephemeral-storage=2Gi",
        "eviction-hard=memory.available<200Mi,nodefs.available<10%,imagefs.available<10%",
        "enforce-node-allocatable=pods",
      ]

      disable_ipv4 = true
      disable_ipv6 = true
    },
    {
      # THE THIRD GENERAL AGENT — the reason system_upgrade_use_drain can be true below.
      #
      # Two schedulable nodes cannot be reduced to one without somewhere for the pods to
      # go, so "drain a node" was not an operation the solo variant could perform. Adding
      # a third is not about total capacity; it is about being able to empty one. Sized
      # identically to agent-large so any pod that fits there fits here.
      name        = "agent-large-2",
      server_type = "cx33",
      location    = var.primary_location,
      labels      = [],
      taints      = [],
      count       = 1

      kubelet_args = [
        "kube-reserved=cpu=100m,memory=256Mi,ephemeral-storage=2Gi",
        "system-reserved=cpu=200m,memory=256Mi,ephemeral-storage=2Gi",
        "eviction-hard=memory.available<200Mi,nodefs.available<10%,imagefs.available<10%",
        "enforce-node-allocatable=pods",
      ]

      disable_ipv4 = true
      disable_ipv6 = true
    },
    {
      name        = "storage",
      server_type = "cx33",
      location    = var.primary_location,
      labels = [
        "node.kubernetes.io/server-usage=storage"
      ],
      taints = [],
      # Scaled to zero on 2026-06-10 when Longhorn was retired; saves one node's monthly
      # cost. The pool stays DEFINED at count = 0 rather than being deleted: agent pools
      # are keyed by list index, so removing an entry re-indexes and recreates every pool
      # after it. Zero is free; deletion is not.
      count = 0

      longhorn_volume_size = 20

      disable_ipv4 = true
      disable_ipv6 = true
    },
    {
      name        = "egress",
      server_type = "cx23",
      location    = var.primary_location,
      labels = [
        "node.kubernetes.io/role=egress"
      ],
      taints = [
        "node.kubernetes.io/role=egress:NoSchedule"
      ],
      # floating_ip = true
      # Optionally associate a reverse DNS entry with the floating IP(s).
      # This is useful in combination with the Egress Gateway feature for hosting certain services in the cluster, such as email servers.
      # floating_ip_rns = "my.domain.com"
      count = 1

      disable_ipv4 = true
      disable_ipv6 = true
    },
    {
      # Dedicated CI node. Tekton pipeline pods (maven+dind+postgres, pnpm+Playwright) are
      # pinned here via a matching toleration + nodeSelector in the gitops triggertemplates,
      # so a build storm can never starve a platform node into NotReady again
      # (root cause: incident-large-dqa-notready 2026-06-13). kured tolerates this taint
      # (see local.kured_tolerations_patch) so the node still reboots for MicroOS updates.
      #
      # MUST stay last in this list: kube-hetzner keys agent nodes by list index, so
      # inserting a pool earlier re-indexes (and recreates) the egress node.
      name        = "agent-ci",
      server_type = "cx33",
      location    = var.primary_location,
      labels = [
        "node.kubernetes.io/role=ci"
      ],
      taints = [
        "node.kubernetes.io/role=ci:NoSchedule"
      ],
      count = 1

      # Reserve CPU/mem/disk for the kubelet+OS so even when CI saturates this node, the
      # kubelet keeps posting status and only the CI pods get evicted — never the node.
      kubelet_args = [
        "kube-reserved=cpu=150m,memory=500Mi,ephemeral-storage=2Gi",
        "system-reserved=cpu=200m,memory=500Mi,ephemeral-storage=2Gi",
        "eviction-hard=memory.available<300Mi,nodefs.available<10%,imagefs.available<10%",
        "enforce-node-allocatable=pods",
      ]

      disable_ipv4 = true
      disable_ipv6 = true
    },
  ]

  load_balancer_type     = "lb11"
  load_balancer_location = var.primary_location

  # Redundant NAT router. In the solo variant this is one server, and it is the most
  # consequential single point of failure in that design: it carries ALL egress, and with
  # control_plane_lb_enable_public_interface = false it also carries the forwarded kube-API
  # port. Losing it takes out cluster egress and the SSH path at the same time, which is
  # also the path you would use to fix it.
  #
  # With redundancy the module builds two routers with a keepalived VIP and puts the
  # standby in standby_location, so the pair does not share a datacentre.
  #
  # CONSEQUENCE WORTH KNOWING BEFORE YOU NEED IT: after a failover, egress leaves from the
  # standby's location and therefore from a DIFFERENT public IP. Anything that allowlists
  # this cluster's egress address by IP — a payment provider, a partner API, a database
  # firewall — must allowlist both addresses, or the failover trades an outage for a
  # subtler one. Both primary IPs are stable resources, so both are knowable up front.
  nat_router = {
    server_type       = "cx23"
    location          = var.primary_location
    enable_sudo       = false
    enable_redundancy = true
    standby_location  = var.secondary_location
  }

  # Redundancy is not free of credentials: the keepalived pair moves the floating IP by
  # calling the Hetzner API, so a token lives ON the routers — the only hosts here with a
  # public interface. Use a SEPARATE token from hcloud_token so it can be revoked on its
  # own. See variable "nat_router_hcloud_token".
  nat_router_hcloud_token = var.nat_router_hcloud_token

  enable_delete_protection = {
    floating_ip   = true
    load_balancer = true
    volume        = true
  }

  etcd_s3_backup = {
    etcd-s3-endpoint   = var.etcd_s3_endpoint
    etcd-s3-access-key = var.etcd_s3_access_key
    etcd-s3-secret-key = var.etcd_s3_secret_key
    etcd-s3-bucket     = var.etcd_s3_bucket
    etcd-s3-region     = var.etcd_s3_region
  }

  enable_cert_manager = true

  # Pinned explicitly, from a security audit on 2026-08-05. The module default is "*",
  # and that is rendered literally as the chart version into the k3s HelmChart custom
  # resource. Every time the helm-controller re-runs the install job — job garbage
  # collection, a k3s restart, an etcd restore, any values change — Helm then pulls
  # whatever the newest cert-manager is at that moment.
  #
  # A major release with a CRD change breaks kubernetes_manifest.letsencrypt and stops
  # all renewals; if the CRD is replaced, Certificate objects are garbage-collected
  # together with their TLS secrets. That is every ingress in the cluster without a
  # valid certificate, at once, triggered by an unrelated restart.
  #
  # The value is the chart that was already running when this was written, so pinning it
  # froze the existing state. It is not an upgrade, and bumping it is a separate change
  # with its own testing.
  cert_manager_version = local.cert_manager_version

  # Longhorn retired 2026-06-10: 0.9 GB of actual data did not justify a dedicated
  # storage node and ~30 extra pods. Databases moved to CSI block volumes, CI caches to
  # local-path. Turning this back on means re-enabling the storage pool above as well.
  enable_longhorn = false

  # k3s local-path-provisioner, for throwaway CI workspaces and build caches — it
  # replaced Longhorn for short-lived single-node volumes.
  #
  # WATCH OUT: enabling it creates a SECOND default StorageClass, which is the ambiguity
  # described at local.storageclass_default_fix_cmd above. Its default annotation is
  # turned off by that command via the kustomize deploy hook, and declared as Terraform
  # state in storageclass.tf so drift is visible. Enable this and skip both and a PVC
  # without an explicit storageClassName can land on node-local storage.
  enable_local_storage = true

  hetzner_ccm_use_helm = true

  # Change to 3, true, true for HA
  longhorn_replica_count = 1

  automatically_upgrade_k3s = true

  # true = actually move pods off a node before upgrading it. The solo variant sets this
  # to FALSE, and that difference is the single clearest illustration of what this variant
  # is for.
  #
  # Why solo has to say false: with only two nodes accepting general workloads, a drain
  # has nowhere to put the evicted pods. On 2026-08-05 that left a node cordoned for 150
  # minutes with 8 pods Pending — one of them Alertmanager, which is why nothing alerted.
  # The module warns about exactly this on system_upgrade_enable_eviction: "Disable this
  # on small clusters to avoid system upgrades hanging since pods resisting eviction keep
  # node unschedulable forever."
  #
  # Why this variant can say true: three general agents plus an autoscaler pool. Emptying
  # one leaves two, and Pending pods bring up a fourth in under three minutes (measured).
  #
  # THE PRECONDITION IS CAPACITY, NOT THIS FLAG. Setting true on a cluster whose remaining
  # nodes cannot absorb the evicted pods reproduces the 2026-08-05 incident exactly. If
  # you shrink the agent pools below, change this back to false in the same commit.
  #
  # Still not surge: k3s' system-upgrade-controller never adds a node before removing one,
  # and a failed upgrade has no automatic rollback. Headroom emulates surge; it does not
  # implement it, and the runbook must cover manual recovery.
  system_upgrade_use_drain = true

  system_upgrade_schedule_window = local.system_upgrade_schedule_window
  initial_k3s_channel            = local.initial_k3s_channel

  # ── Cluster autoscaler: on-demand third worker (POC, M1 parity row 3.5) ──────
  #
  # WHAT THIS FIXES, and what it does not. The autoscaler scales on SCHEDULING pressure —
  # it adds a node when pods are Pending. So:
  #   fixes  : drain/eviction headroom. On 2026-08-05 a k3s agent upgrade cordoned
  #            agent-small and left 8 pods Pending for 2.5 hours because there was
  #            nowhere to put them. That is exactly a Pending-pod signal; with this the
  #            gap becomes minutes.
  #   does NOT fix: CPU starvation. On 2026-08-08 agent-large went NotReady under a
  #            cold-start storm — every pod restarted IN PLACE, nothing was Pending, so
  #            the autoscaler would have seen no signal at all. Load is not scheduling
  #            pressure. That problem needs a third STATIC worker, or fewer pods per node.
  #
  # Measured context (2026-08-08): agent-small sits at 97% of allocatable CPU requests and
  # 88% memory. The cluster is already at the edge of what it can schedule, so min_nodes=0
  # may not stay at 0 for long — that is information the POC is meant to produce.
  #
  # UNTAINTED on purpose: the whole point is that evicted pods can land here during a
  # drain. A taint would make it useless for the case it exists to solve.
  #
  # No public IPs, matching every other pool — egress goes through the NAT router.
  #
  # Credentials: the autoscaler reads the EXISTING kube-system/hcloud secret
  # (templates/autoscaler.yaml.tpl:182), the same project-wide token the CCM and CSI
  # already mount. It adds no new credential exposure — but it does add a new consumer
  # that can create and delete nodes on its own initiative. See M6 axis E.
  autoscaler_nodepools = local.autoscaler_nodepools


  autoscaler_disable_ipv4 = true
  autoscaler_disable_ipv6 = true

  # etcd snapshot schedule and retention (M1 parity row 3.2).
  #
  # Measured before changing anything: no etcd-snapshot settings in config.yaml at all, so
  # k3s defaults applied — every 12 hours, keep 5. That is an RPO of up to 12 hours and a
  # retention window of ~2.5 days. Restore a Friday-evening mistake on Monday and the
  # snapshot that predates it is already gone.
  #
  # Now every 4 hours, keep 42 = a rolling 7 days, and RPO drops from 12h to 4h.
  #
  # Sized against measurement, not taste: snapshots are 40-51 MB (241 MB for the current 5).
  # 42 x ~51 MB is ~2.1 GB local, against 13 GB free on the control plane's 39 GB disk. The
  # same retention applies to the S3 copy (etcd_s3_backup, already configured), where 2.1 GB
  # is negligible.
  #
  # Delivered via control_planes_custom_config rather than k3s_exec_server_args on purpose:
  # exec args are baked into the INSTALL command (module locals.tf:243), so they reach new
  # nodes only and would have left this running control plane untouched. custom_config is
  # merged into config.yaml, which the module pushes and which triggers a k3s restart.
  control_planes_custom_config = {
    etcd-snapshot-schedule-cron = "0 */4 * * *"
    etcd-snapshot-retention     = 42

    # etcd across two datacentres. The defaults (100 ms heartbeat, 1000 ms election
    # timeout) assume members share a LAN. They do not here, and etcd's failure mode when
    # they are too tight is not a crash: it is a leader election storm — members declare
    # the leader dead because a heartbeat was late, elect a new one, and repeat. The API
    # then stalls for seconds at a time with nothing obviously broken.
    #
    # etcd's own guidance is heartbeat >= round-trip time and election timeout at least
    # 10x heartbeat. The values below are sized for a same-country hop, which is why
    # var.secondary_location defaults to a nearby datacentre rather than a distant one.
    #
    # THESE NUMBERS ARE NOT UNIVERSAL. Measure the actual RTT between your two locations
    # and raise them if it exceeds ~30 ms; a longer election timeout also means a longer
    # outage when a leader genuinely dies, so this is a trade to make deliberately and not
    # a value to inflate for safety.
    etcd-arg = [
      "heartbeat-interval=250",
      "election-timeout=2500",
    ]
  }

  # Not in local.kustomization_trigger_fingerprint on purpose: this input drives
  # terraform_data.audit_policy (control_planes.tf:220), not the kustomization. Putting
  # it in the fingerprint would re-run the kured patch for no reason.
  k3s_audit_policy_config = local.k3s_audit_policy

  # ── Cluster access identity: deliberately NOT configured ────────────────────
  #
  # Managed Kubernetes maps cloud IAM identities to RBAC, so access is per-person,
  # auditable and revocable. Here, access is a static client certificate in the kubeconfig:
  # no per-user identity, and no revocation short of rotating the CA.
  #
  # kube-hetzner 2.19.2 exposes `authentication_config` (k3s structured authentication),
  # so wiring an external OIDC provider is a supported one-liner:
  #
  #   authentication_config = file("${path.module}/authentication-config.yaml")
  #
  # It is left off on purpose, and the reason is a bootstrap circularity worth
  # understanding before you turn it on: if the identity provider runs INSIDE this
  # cluster, then losing the cluster loses the way to log in and fix it. If you enable
  # OIDC, either host the IdP elsewhere or keep the certificate kubeconfig as a
  # break-glass credential — which means keeping the revocation problem you were trying
  # to solve, for one account.
  #
  # Workload identity (IRSA / GKE WI / AKS managed identity) has no equivalent at all.
  # Pods here keep long-lived secrets. That is structural, not an omission.

  automatically_upgrade_os = true
  #
  # Runs on every node after the k3s install command. In this variant that matters more
  # than in solo: there are THREE control planes, each with its own manifests directory and
  # its own deploy controller, so a skip file placed only on the first one leaves two nodes
  # able to reset the annotation. Every node gets it here.
  postinstall_exec = [
    local.local_storage_skip_cmd,
  ]

  preinstall_exec = [
    # Wait for outbound internet before the rest of the bootstrap, but give up rather
    # than spin forever. This loop had no exit condition: a node whose egress never came
    # up (NAT router not ready, firewall change, Hetzner incident) sat here indefinitely,
    # so cloud-init never finished, so the provisioner waiting on the node never returned,
    # so `terraform apply` hung — holding the S3 state lock — with no diagnostic beyond
    # 'Waiting for internet...' scrolling on a console nobody was watching.
    # 60 attempts x (5s timeout + 5s sleep) is a ~10 minute ceiling; failing here fails
    # the node visibly instead of hanging the whole apply.
    "i=0; until curl -sf --max-time 5 https://get.k3s.io > /dev/null; do i=$((i+1)); if [ $i -ge 60 ]; then echo 'No outbound internet after ~10 minutes - aborting bootstrap'; exit 1; fi; echo 'Waiting for internet...'; sleep 5; done",
    # Pin version (F20): avoids pulling `latest` on every boot. Update TS_VERSION + TS_SHA256 together when upgrading.
    # To get the SHA256 for a new version: curl -fsSL https://pkgs.tailscale.com/stable/tailscale_X.Y.Z_amd64.tgz | sha256sum
    "curl -fsSL https://pkgs.tailscale.com/stable/tailscale_1.80.3_amd64.tgz -o /tmp/tailscale.tgz",
    "echo '9e93254449842b6051963752241d3ba753d6a9bccdd4f6f204df4ee50926b827 /tmp/tailscale.tgz' | sha256sum -c - || { echo 'Tailscale tarball SHA256 mismatch — aborting bootstrap'; exit 1; }",
    "mkdir -p /var/lib/tailscale /run/tailscale",
    "tar -C /tmp -xzf /tmp/tailscale.tgz",
    "cp /tmp/tailscale_*/tailscale /usr/local/bin/tailscale",
    "cp /tmp/tailscale_*/tailscaled /usr/local/bin/tailscaled",
    "rm -rf /tmp/tailscale*",
    "tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock &",
    "sleep 5",
    # F10: advertise only the Hetzner private network /16, not the entire 10.0.0.0/8
    "tailscale up --authkey=${var.tailscale_auth_key} --advertise-routes=10.0.0.0/16 --accept-dns=false --advertise-tags=tag:k8s-nat"
  ]

  restrict_outbound_traffic = true

  # restrict_outbound_traffic (above) allows only DNS, HTTP, HTTPS and NTP outbound.
  # Anything else a workload needs to reach has to be named explicitly, and the failure
  # mode when it is not is quiet: no firewall log, no rejection, just a connection that
  # times out minutes later. The case that found this was an authenticated SMTP
  # submission on port 587 — all alert mail sat in the relay's queue with
  # "Operation timed out" and nothing else was wrong with the cluster.
  #
  # The rules themselves are an input with an empty default, because which destinations
  # you open is a decision for whoever runs the cluster, not a value to inherit. Scope
  # each one to the narrowest destination network that works; the variable refuses
  # 0.0.0.0/0, which would undo restrict_outbound_traffic cluster-wide.
  #
  # Inbound UDP 41641 (Tailscale direct connections) is deliberately NOT opened. A direct
  # connection needs outbound UDP too, which would weaken restrict_outbound_traffic for
  # every node; relayed connections over DERP are slower but cost nothing here.
  extra_firewall_rules = var.extra_firewall_rules

  firewall_kube_api_source = var.firewall_kube_api_source

  firewall_ssh_source = var.firewall_ssh_source

  cni_plugin = "cilium"

  cilium_egress_gateway_enabled = true

  cilium_hubble_enabled = true

  dns_servers = [
    "1.1.1.1",
    "8.8.8.8",
    "2606:4700:4700::1111",
  ]

  use_control_plane_lb = true

  # The kube-API is served tailscale-only, via the control-plane node's tailnet address.
  # That address has to appear in two places at once and they must never drift: it must
  # be a cert SAN (or kubectl rejects the TLS handshake) AND it must be what kubeconfig
  # and the kubernetes/helm providers dial. Both therefore read the same variable —
  # previously both were hardcoded to the same literal, which worked only for as long as
  # nobody edited one of them.
  #
  # BOOTSTRAP ORDER, for a cluster that does not exist yet: the address is assigned by
  # Tailscale when the control plane first joins the tailnet, so it cannot be known in
  # advance. Build in two passes — see docs/RUNBOOK.md:
  #   1. apply with var.kube_api_tailnet_address unset and the public LB interface still
  #      enabled, so the node can come up and register with Tailscale;
  #   2. read the assigned address, set the variable, apply again. The cert is reissued
  #      with the new SAN and the public interface can then be closed.
  # Skipping pass 1 is why a green-field build used to fail outright on this line.
  additional_tls_sans       = [var.kube_api_tailnet_address]
  kubeconfig_server_address = var.kube_api_tailnet_address

  # Close the public control-plane LB permanently: this removes the load balancer's
  # public interface entirely. NOTE: with a nat_router present, the module turns on
  # enable_cp_lb_port_forward, which rewrites the NAT-router cloud-init -> a ONE-TIME
  # NAT-router rebuild (public IP preserved via the stable primary-IP resource; kubectl over
  # the tailnet is unaffected). The resulting 6443 forward on the NAT router's public IP is
  # firewall-gated to firewall_kube_api_source (100.64.0.0/10), so it is not publicly reachable.
  control_plane_lb_enable_public_interface = false

  cilium_merge_values = local.cilium_merge_values

  hetzner_ccm_merge_values = local.hetzner_ccm_merge_values

  longhorn_merge_values = local.longhorn_merge_values

  # Pinned explicitly, same audit and same mechanism as cert-manager above: the module
  # default is "" (= latest). Setting traefik_merge_values below makes it worse rather
  # than safer — the custom resource spec changes on apply, so the helm-controller re-runs
  # the job, with whatever chart is current that day. A chart major bump changes
  # IngressRoute and annotation semantics and takes down every ingress, and `terraform
  # plan` showed nothing at all beforehand. The value is the chart that was already
  # running when this was pinned.
  traefik_version = local.traefik_version

  # All three Traefik replicas had been scheduled onto one node (audit 2026-06-12), so a
  # single node reboot took down all ingress at once — three replicas providing exactly
  # as much availability as one. Soft anti-affinity spreads them.
  #
  # Deliberately 'preferred' and not 'required': with only two schedulable agent nodes,
  # 'required' would leave the third replica Pending forever, which trades one failure
  # mode for another.
  traefik_merge_values = local.traefik_merge_values
}
