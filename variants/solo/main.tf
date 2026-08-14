# SPDX-License-Identifier: Apache-2.0
#
# Apache-2.0, not MIT, even though this file is attributed in NOTICE. It shares 30 of 249
# substantive unique lines with upstream's kube.tf.example (~12 %) — derivation at the
# level of configuration rather than copying, which is why the attribution is there out of
# caution while the licence stays the project's own. The near-verbatim file is the Packer
# template, and that one carries an MIT identifier. See ADR-0001 and ADR-0005.

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

  # EVERY nodepool names its OS, and green-field is the only build that can tell you why.
  #
  # 3.1.0 resolves an unset nodepool `os` through local.{control_plane,agent}_nodepool_default_os:
  # a pool that already has servers keeps whatever those servers run (this cluster: microos),
  # and a pool that does NOT yet exist gets "leapmicro". Production therefore saw no diff at
  # all, and a green-field build failed at PLAN time on 2026-08-11:
  #
  #   Error: Resource not found
  #     with module.kube-hetzner.data.hcloud_image.leapmicro_x86_snapshot[0]
  #     Resource (image) was not found using label selector:
  #     leapmicro-snapshot=yes,kube-hetzner/os=leapmicro,kube-hetzner/k8s-distro=k3s
  #
  # packer/hcloud-microos-snapshots.pkr.hcl builds MicroOS and only MicroOS, so the snapshot
  # the module now looks for by default is one this repository never produces. Naming the OS
  # makes the two agree, and makes the running cluster's OS a written fact rather than an
  # inference from labels the module started writing in this same upgrade.
  #
  # Moving to Leap Micro is the upstream recommendation for NEW clusters and is a separate
  # decision: it needs a new Packer template and it cannot be proven against this cluster.
  node_os = "microos"

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
  # Pinned during the 3.1.0 upgrade, at the version the cluster is ALREADY running
  # (measured: `kubectl -n kube-system get ds cilium -o jsonpath=...` -> cilium:v1.17.0).
  # It was inherited before: 2.19.2 defaulted to 1.17.0 and this file said nothing, so the
  # module bump to 3.1.0 — whose default is 1.19.3 — would have carried the CNI across two
  # minor versions inside a plan whose headline change was an input rename. That is the
  # same silent-inheritance failure the note above describes, one layer down. Moving Cilium
  # is a change with its own upgrade notes and its own blast radius; it gets its own PR.
  cilium_version           = "1.17.0"
  cilium_merge_values      = <<-EOT
encryption:
  enabled: true
  type: wireguard
  EOT
  hetzner_ccm_merge_values = <<-EOT
env:
  HCLOUD_LOAD_BALANCERS_USE_PRIVATE_IP:
    value: "true"
  HCLOUD_LOAD_BALANCERS_DISABLE_PRIVATE_INGRESS:
    value: "true"
  HCLOUD_LOAD_BALANCERS_LOCATION:
    value: "nbg1"
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
  #
  # 3.1.0 renamed the MODULE INPUT to k3s_channel and changed its default from "v1.33" to
  # "stable" — so the value below stopped being a no-op the moment the module moved, and
  # is now the only thing keeping this cluster on v1.33. The LOCAL deliberately keeps the
  # v2 name: it is also a key in local.kustomization_trigger_fingerprint, and that
  # fingerprint is a sha1 over the JSON, key names included. Renaming the key would change
  # the hash and re-run the kured/storageclass patch hook for no reason at all.
  # A CHANNEL NAME, BUT NOT A FLOATING ONE — and that changed under us, so it is worth
  # stating precisely rather than assuming either way.
  #
  # Under kube-hetzner 2.19.2 a channel meant "whatever k3s currently publishes as latest
  # in this minor", which is genuinely unpinned: two people building a week apart get
  # different patch versions. 3.1.0 replaced that with a release manifest reviewed against
  # the module version, so `k3s_channel = "v1.33"` now resolves to a fixed
  # `v1.33.13+k3s2` (module locals.tf, k3s_channel_release_manifest). The bootstrap is
  # therefore deterministic for a given module pin, and this line is NOT the odd one out
  # among the exact versions above it.
  #
  # What can still move is afterwards: upstream's own description notes that
  # System-Upgrade-Controller plans may keep following the live channel, so the version a
  # cluster RUNS can drift from the version it was BUILT with. That is a property of the
  # upgrade path, not of this line.
  #
  # Set `k3s_version` (e.g. "v1.29.6+k3s2") to pin exactly and supersede the channel.
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

  autoscaler_nodepools = [
    {
      name        = "autoscaled"
      server_type = "cx33"
      location    = "nbg1"
      min_nodes   = 0
      max_nodes   = 1
      os          = local.node_os
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
    # Same rule, applied to the input the 3.1.0 upgrade added: cilium_version is one of the
    # entries in the module's `versions` trigger, so it belongs here too.
    cilium_version = local.cilium_version
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
  cluster_token = var.k3s_token

  source = "kube-hetzner/kube-hetzner/hcloud"

  # WHAT A REGISTRY PIN ACTUALLY PINS, which is not what people usually assume.
  #
  # "A module pinned to a git tag is pinned to something mutable" is true for a git
  # source and false for a registry source, and the difference is invisible in this file.
  # The registry resolved this version to a commit at publish time and hands Terraform
  # that commit, never the tag:
  #
  #   curl -sSI https://registry.terraform.io/v1/modules/kube-hetzner/kube-hetzner/hcloud/3.1.0/download
  #   x-terraform-get: git::https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner
  #                    ?ref=ed524efe85377a62f1aecf34422c8ab1b073a75b
  #
  # So force-moving the upstream v3.1.0 tag would not change a byte of what gets downloaded
  # here. Rewriting this as a git source with an explicit ?ref=<sha> would buy no
  # immutability, cost a full clone on every init, and move the record of the correct SHA
  # from the registry into a comment we maintain.
  #
  # What IS still possible: the module owner deleting and republishing version 3.1.0
  # against a different commit. The SHA above is what to compare against — the curl
  # command is the check, and it belongs in CI. Terraform does not lock modules the way it
  # locks providers, so the version below is the only thing holding this in place.
  #
  # ── THIS BLOCK USED TO SAY "THIS PIN IS IMMUTABLE", AT 2.19.2. Both reasons it gave were
  # real when written, and neither survived being re-measured on 2026-08-11:
  #
  #  1. "2.20.0 removed assignee_type from the NAT-router hcloud_primary_ip resources,
  #     which provider 1.60.1 still REQUIRES." Moot rather than fixed: 3.1.0 declares
  #     hcloud >= 1.62.0, so 1.60.1 cannot be installed against it at all —
  #     `terraform init` exits 1 with "no available releases match the given constraints
  #     1.60.1, >= 1.62.0". Against the provider now locked (1.68.0) the argument's absence
  #     is a non-event: both nat_router primary IPs are refreshed and appear in NO change
  #     list in the 3.1.0 plan.
  #
  #  2. "2.19.3 added trimspace(var.ssh_public_key); our state holds the key WITH a
  #     trailing newline, so trimspace creates a phantom hcloud_ssh_key diff that cascades
  #     into rebuilding the NAT router." Half true. The trimspace is still there in 3.1.0
  #     and the phantom diff is REAL — the Hetzner API itself returns 108 bytes ending in
  #     \n for ssh_key 111717378, so the trimmed config can never match the refreshed
  #     state and hcloud_ssh_key.k3s[0] is replaced. The CASCADE is gone: 3.1.0 added
  #     ssh_keys and user_data to hcloud_server.nat_router's ignore_changes, so the router
  #     is updated in place (labels) and every other server is untouched. A replaced SSH
  #     key object costs nothing at runtime — Hetzner consumes ssh_keys only at server
  #     creation, and all five servers ignore that attribute.
  #
  # The upgrade happened because 2.19.2 declared `data "hcloud_image" "microos_arm_snapshot"`
  # with no count — see enabled_architectures below for why that made a green-field build
  # impossible while Hetzner's ARM fleet was sold out.
  version = "3.1.0"

  # THE REASON THIS MODULE WAS UPGRADED AT ALL, in one input.
  #
  # Every node here is x86 (cx23/cx33). 2.19.2 did not care: it declared
  # `data "hcloud_image" "microos_arm_snapshot"` with no count, so Terraform read the ARM
  # snapshot on EVERY plan, x86-only cluster or not — and the singular data source errors
  # when nothing matches. That is survivable for this cluster because its ARM snapshot has
  # existed since 2026-03-08. It is fatal for a green-field build: on 2026-08-10 all four
  # cax types were unavailable in nbg1-dc3, hel1-dc2 and fsn1-dc14 (measured via GET
  # /v1/datacenters), so no ARM snapshot could be created, so M4-b could not even PLAN.
  #
  # 3.1.0 gates the lookup twice over: the data source is plural (`hcloud_images`, empty
  # list instead of an error) and carries
  #   count = contains(var.enabled_architectures, "arm") && local.os_arch_requirements.microos.arm && ...
  # Naming x86 here closes the first clause explicitly rather than relying on the second.
  enabled_architectures = ["x86"]

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

  # Named explicitly rather than inherited. The value is the module's own default, so this
  # changes nothing today — and that is the point: the name is currently INHERITED, so a
  # module bump that changed the default would rename every resource in the project with
  # no diff here to show it. Same reasoning as initial_k3s_channel above.
  #
  # Not part of the kustomization trigger set — verified against the module: cluster_name
  # feeds only a local backup filename, none of the helm values locals. So it needs no
  # entry in local.kustomization_trigger_fingerprint.
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
  # 3.1.0 replaced the three flat extra_kustomize_* inputs with ONE ordered map. The key
  # is the order number and must be a positive numeric string; "1" is the only set here,
  # and source_folder repeats what extra_kustomize_folder defaulted to in 2.19.2
  # ("extra-manifests"), because in v3 an unset source_folder means an empty set, not the
  # old default. post_commands is the old extra_kustomize_deployment_commands verbatim.
  user_kustomizations = {
    "1" = {
      source_folder = "extra-manifests"
      kustomize_parameters = {
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
      post_commands = "kubectl -n kube-system patch daemonset kured --type=strategic -p '${local.kured_tolerations_patch}' && ${local.longhorn_small_no_sched_cmd} && ${local.storageclass_default_fix_cmd} && ${local.local_storage_skip_cmd}"
    }
  }

  control_plane_nodepools = [
    {
      name        = "control-plane-nbg1-1",
      server_type = "cx23",
      location    = "nbg1",
      labels      = [],
      taints      = [],
      count       = 1

      os = local.node_os

      enable_public_ipv4 = false
      enable_public_ipv6 = false
    },
    {
      name        = "control-plane-nbg1-2",
      server_type = "cx23",
      location    = "nbg1",
      labels      = [],
      taints      = [],
      count       = 0

      os = local.node_os

      enable_public_ipv4 = false
      enable_public_ipv6 = false
    },
    {
      name        = "control-plane-hel1",
      server_type = "cx23",
      location    = "hel1",
      labels      = [],
      taints      = [],
      count       = 0

      os = local.node_os

      enable_public_ipv4 = false
      enable_public_ipv6 = false
    }
  ]

  agent_nodepools = [
    {
      name = "agent-small"
      # Resized cx23(4GB)→cx33(8GB) 2026-06-13: the DB node (6 postgres + keycloak-pg +
      # redis, all 7 hcloud-volumes attach here) was memory-bound at ~85%. cx33 doubles RAM.
      server_type = "cx33",
      location    = "nbg1",
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

      os = local.node_os

      enable_public_ipv4 = false
      enable_public_ipv6 = false

    },
    {
      name        = "agent-large",
      server_type = "cx33",
      location    = "nbg1",
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

      os = local.node_os

      enable_public_ipv4 = false
      enable_public_ipv6 = false
    },
    {
      name        = "storage",
      server_type = "cx33",
      location    = "nbg1",
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

      os = local.node_os

      enable_public_ipv4 = false
      enable_public_ipv6 = false
    },
    {
      name        = "egress",
      server_type = "cx23",
      location    = "nbg1",
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

      os = local.node_os

      enable_public_ipv4 = false
      enable_public_ipv6 = false
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
      location    = "nbg1",
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

      os = local.node_os

      enable_public_ipv4 = false
      enable_public_ipv6 = false
    },
  ]

  load_balancer_type     = "lb11"
  load_balancer_location = "nbg1"

  nat_router = {
    server_type       = "cx23"
    location          = "nbg1"
    enable_sudo       = false
    enable_redundancy = false # set true + standby_location for HA
  }

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

  # Change to 3, true, true for HA
  longhorn_replica_count = 1

  automatically_upgrade_kubernetes = true

  # false = cordon during a k3s upgrade, do not drain. This is a small-cluster setting
  # and it comes from an incident on 2026-08-05.
  #
  # With true, the system-upgrade-controller tries to move every pod off a node before
  # upgrading it. A cluster this size cannot do that: only TWO nodes accept general
  # workloads (the control plane, CI and egress pools are all tainted), and the other one
  # runs at around 93% memory. The 17 pods on the node being upgraded did not fit, so the
  # drain never completed, the upgrade job hit its deadline (DeadlineExceeded), and the
  # node was left CORDONED — for 150 minutes, with 8 pods Pending. One of those pods was
  # Alertmanager, which is why no alert fired about any of it.
  #
  # The module documents this on system_upgrade_enable_eviction: "Disable this on small
  # clusters to avoid system upgrades hanging since pods resisting eviction keep node
  # unschedulable forever."
  #
  # With false the node keeps running through the upgrade: cordon -> update k3s in place
  # -> uncordon. Pods experience an agent restart instead of a migration, which is not a
  # new class of disruption here — kured already runs with --drain-timeout=5m
  # --force-reboot=true and stops those same pods every night.
  #
  # This is a mitigation, not a fix. The fix is enough capacity to empty a node: a third
  # worker, either static or via the autoscaler configured below. NEVER delete the
  # zero-count pool above to make room in the list — agent pools are keyed by index, and
  # removing one rebuilds every pool after it.
  system_upgrade_use_drain = false

  system_upgrade_schedule_window = local.system_upgrade_schedule_window
  k3s_channel                    = local.initial_k3s_channel

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


  autoscaler_enable_public_ipv4 = false
  autoscaler_enable_public_ipv6 = false

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
  }

  # Not in local.kustomization_trigger_fingerprint on purpose: this input drives
  # terraform_data.audit_policy (control_planes.tf:220), not the kustomization. Putting
  # it in the fingerprint would re-run the kured patch for no reason.
  audit_policy_config = local.k3s_audit_policy

  automatically_upgrade_os = true
  #
  # Runs on every node after the k3s install command. This is what makes a REBUILT control
  # plane safe: it arrives with the skip already in place, so it never re-applies the addon
  # and never resets the annotation. Changing this changes cloud-init, which the module puts
  # in ignore_changes (modules/host/main.tf) — so it does NOT rebuild running nodes; it only
  # takes effect on new ones, which is precisely the set of nodes that need it.
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
    # See var.tailscale_advertise_routes for why this is a variable rather than a literal:
    # every node runs this line, so two clusters on one tailnet fight over the same prefix.
    # The default reproduces the literal that used to be here, byte for byte.
    "tailscale up --authkey=${var.tailscale_auth_key}${length(var.tailscale_advertise_routes) > 0 ? " --advertise-routes=${join(",", var.tailscale_advertise_routes)}" : ""} --accept-dns=false --advertise-tags=tag:k8s-nat"
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

  # An INVERTED rename with an inverted default, which is the dangerous combination: 2.19.2
  # had block_icmp_ping_in = false (ping allowed), 3.1.0 has allow_inbound_icmp = false
  # (ping blocked). Same literal `false` in both, opposite meaning — so saying nothing here
  # would have silently dropped the firewall's ICMP rule during a version bump.
  #
  # true keeps today's behaviour. Measured before choosing: three ICMP echoes to the NAT
  # router's public IPv4 (read out of state, not written down here) answered, 0% loss —
  #   terraform state show 'module.kube-hetzner.hcloud_primary_ip.nat_router_primary_ipv4[0]'
  # is where that address comes from. Every node has enable_public_ipv4 =
  # false, so that router is the ONLY address this rule applies to — and with the API on a
  # tailnet, an ICMP echo to it is the one liveness check that still works from outside when
  # the tailnet itself is the thing that is broken. docs/ARCHITECTURE.md names the missing
  # break-glass path as a known cost of the tailnet posture; this is not the change that
  # should quietly make it worse. Blocking it is a defensible hardening step — as its own PR.
  allow_inbound_icmp = true

  cni_plugin = "cilium"

  # NOT a straight rename of 2.19.2's disable_kube_proxy, and the difference is the whole
  # point. 2.19.2 hardcoded `kubeProxyReplacement: true` and `bpf.masquerade: true` in the
  # Cilium values NO MATTER what disable_kube_proxy said; that flag only decided whether
  # k3s ALSO started its own embedded kube-proxy. We never set it, so this cluster has been
  # running both: Cilium replacing kube-proxy, and k3s starting one anyway.
  #
  # 3.1.0 ties the Cilium values to this input — `kubeProxyReplacement: ${!enable_kube_proxy}`
  # and `bpf.masquerade: ${!enable_kube_proxy}` — so the literal translation of the old
  # default (enable_kube_proxy = true) would flip BOTH of those to false and tear out the
  # dataplane this cluster actually runs. Measured on the live cluster before choosing:
  #
  #   kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.kube-proxy-replacement}'
  #     -> true
  #   ... '{.data.enable-bpf-masquerade}'   -> true
  #
  # false is therefore the value that keeps Cilium exactly as deployed. It is also the only
  # value 3.1.0 accepts here at all: validation-contract.tf:1112 fails the plan outright
  # because cilium_egress_gateway_enabled requires kube-proxy replacement, and that egress
  # gateway is what pins outbound traffic to the dedicated egress node's IP.
  #
  # WHAT IT CHANGES ON THE NEXT APPLY: k3s stops starting the redundant embedded kube-proxy
  # (`disable-kube-proxy: true` lands in config.yaml). Cilium has been serving that role
  # since the cluster was built, so this removes a duplicate, not the implementation.
  enable_kube_proxy = false

  cilium_version = local.cilium_version

  cilium_egress_gateway_enabled = true

  cilium_hubble_enabled = true

  dns_servers = [
    "1.1.1.1",
    "8.8.8.8",
    "2606:4700:4700::1111",
  ]

  enable_control_plane_load_balancer = true

  # The kube-API is served tailscale-only, via the control-plane node's tailnet address.
  # That address has to appear in two places at once and they must never drift: it must
  # be a cert SAN (or kubectl rejects the TLS handshake) AND it must be what kubeconfig
  # and the kubernetes/helm providers dial. Both therefore read the same variable —
  # previously both were hardcoded to the same literal, which worked only for as long as
  # nobody edited one of them.
  #
  # BOOTSTRAP ORDER, for a cluster that does not exist yet: the address is assigned by
  # Tailscale when the control plane first joins the tailnet, so it cannot be known in
  # advance. Build in two passes — see var.bootstrap_phase and docs/RUNBOOK.md:
  #   1. terraform apply -var bootstrap_phase=true — no tailnet SAN, and the control-plane
  #      LB keeps its public interface so the apply can reach the API at all;
  #   2. read the assigned address, set kube_api_tailnet_address, apply again. The cert is
  #      reissued with the new SAN and the public interface closes.
  #
  # THE FLAG IS NEW AND THE REASON IS EMBARRASSING. This comment described those two
  # passes for months while the configuration made them impossible: the variable had no
  # default, so "apply with it unset" is something Terraform refuses before it plans, and
  # the public interface below was hardcoded false. The first green-field build ever
  # attempted stopped here, at plan time. Documentation that has never been executed is a
  # hypothesis.
  additional_tls_sans       = var.bootstrap_phase ? [] : [var.kube_api_tailnet_address]
  kubeconfig_server_address = var.bootstrap_phase ? "" : var.kube_api_tailnet_address

  # Close the public control-plane LB permanently: this removes the load balancer's
  # public interface entirely. NOTE: with a nat_router present, the module turns on
  # enable_cp_lb_port_forward, which rewrites the NAT-router cloud-init -> a ONE-TIME
  # NAT-router rebuild (public IP preserved via the stable primary-IP resource; kubectl over
  # the tailnet is unaffected). The resulting 6443 forward on the NAT router's public IP is
  # firewall-gated to firewall_kube_api_source (100.64.0.0/10), so it is not publicly reachable.
  #
  # Open ONLY during pass 1 of a green-field build (var.bootstrap_phase), because that
  # apply has to reach an API whose tailnet address does not exist yet. Closed for every
  # apply after it, which is what the default false means: an operator who never thinks
  # about this flag gets the closed state.
  #
  # 3.1.0 renamed this input to control_plane_load_balancer_enable_public_network. Same
  # meaning, same polarity — unlike allow_inbound_icmp and enable_kube_proxy above.
  control_plane_load_balancer_enable_public_network = var.bootstrap_phase

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
