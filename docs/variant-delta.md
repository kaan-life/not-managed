# Variant delta

**Generated — do not edit.** Regenerate with `./tools/gen-variant-delta.sh`.

The exact difference between `variants/solo` and `variants/ha`. The two directories are
independent copies by design (ADR-0007), so this file is how divergence stays visible: a
change to one variant that should have been made to both shows up here, in the same pull
request that caused it.

Everything below is `diff -ru variants/solo variants/ha`, with timestamps stripped.

```diff
diff -ru -x .terraform -x .terraform.lock.hcl -x backend.hcl -x secrets.auto.tfvars -x '*.tfstate*' -x __pycache__ variants/solo/README.md variants/ha/README.md
--- variants/solo/README.md
+++ variants/ha/README.md
@@ -1,123 +1,114 @@
-# Variant: solo
+# Variant: ha
 
-> **Draft quickstart.** Written before the green-field build that verifies it. Every step
-> below is either exercised in the running cluster this variant was derived from, or
-> reasoned from the code — but the sequence as a whole has not yet been run start to
-> finish by someone with no prior knowledge. That run is what turns this into the real
-> README, with measured timings and whatever manual repairs it needed.
-
-One control plane, two general-purpose agents, a dedicated CI node, a dedicated egress
-node, and a NAT router. The Kubernetes API is reachable only over a Tailscale tailnet;
-no node has a public IPv4 except the NAT router.
-
-**This is the variant that runs a real workload.** Everything in it exists because
-something happened: the pinned CSI version is there because an older one reformatted a
-production database volume during a node failover; the kured tolerations patch is there
-because two nodes silently stopped rebooting for three days; `system_upgrade_use_drain`
-is `false` because a drain with nowhere to put the pods cordoned a node for two and a
-half hours. The comments explain each one. Read them before deleting a line.
+> **Draft quickstart, and a stronger warning than the one on `solo`.** This variant has
+> **never been applied to anything.** It was authored in this repository, derived from the
+> variant that runs a real workload, and at the time of writing it has been verified only
+> by static means: `terraform validate`, and a plan that resolves the full 46-resource
+> graph against an empty state.
+>
+> It has **not** been booted. The control-plane kill and the etcd restore that this design
+> exists to survive have **not** been executed. Until they have, treat every availability
+> claim here as a design intention rather than a measurement — and read the `solo` variant
+> if you need something whose failure modes are known.
+
+Three control planes across two datacentres, three general-purpose agents, a cluster
+autoscaler, a dedicated CI node, a dedicated egress node, and a redundant NAT router.
+Same architecture as `variants/solo`, different operating point.
 
 ## Choose this variant if
 
-- one operator, one cluster, and a control-plane restart is an inconvenience rather than
-  an incident;
-- the bill matters (this is roughly 70 % of the cost of the `ha` variant before any
-  autoscaling);
-- you can tolerate the API being unavailable while a single control plane reboots — pods
-  keep running, but scheduling, self-healing, GitOps sync and every `kubectl` stop.
-
-Choose `variants/ha` instead if you need the API to survive losing a node or a
-datacentre, or if you need to be able to drain a worker. See the root README for the
-side-by-side table.
-
-## Prerequisites
-
-| | |
-|---|---|
-| Terraform | ≥ 1.10 (`required_version = "~> 1.10"`) |
-| Packer | required for the first build only — `init.sh` builds the MicroOS snapshot |
-| A Hetzner Cloud project | with a read-write API token |
-| S3-compatible object storage | two buckets: Terraform state and etcd snapshots. **Enable versioning on the state bucket.** |
-| A Tailscale tailnet | plus an auth key; the kube-API is served only there |
-| A GitHub organisation | with an App (for ArgoCD repo access) and an OAuth App (for SSO) |
-| A companion GitOps repository | see `docs/adr/0008` — or set `SKIP_TEKTON_BOOTSTRAP=1` |
-| A domain | with DNS you control, for the ArgoCD ingress |
-| `kubectl`, `hcloud`, `python3`, `git` | on the machine running Terraform |
-
-## Build
+- the Kubernetes API has to survive losing a node — with one control plane, a reboot
+  stops scheduling, self-healing, GitOps sync and every `kubectl`, even though running
+  pods carry on;
+- you need to be able to **drain** a worker, for an upgrade or to move a workload. That
+  is not a configuration flag, it is spare capacity: `solo` cannot do it, and this
+  variant can only do it because of the third agent;
+- one datacentre going away should cost you availability, not the cluster.
+
+Choose `variants/solo` if none of those are true. This one costs about **1.4×** as much
+before any autoscaling, and roughly 1.8× with the autoscaler at its configured ceiling.
+Three control planes are three things to patch, not one.
+
+## What differs from `solo`, and what each difference buys
+
+| Change | Buys | Costs |
+|---|---|---|
+| 3 control planes, split 2 + 1 across locations | API survives losing one node; quorum survives losing one member | +2 × cx23; you still operate etcd, and losing the *primary* location still costs the cluster |
+| 3 general agents instead of 2 | a drain has somewhere to put the pods | +1 × cx33 |
+| `system_upgrade_use_drain = true` | pods move off a node before it is upgraded, instead of riding out a restart | only safe while the headroom above exists |
+| Autoscaler `max_nodes = 3` | Pending pods get a node in under three minutes | up to +3 × cx33 when it fires |
+| Redundant NAT router | egress and the forwarded API port survive losing one router | +1 × cx23, **and egress leaves from a different public IP after failover** |
+| `etcd-arg` heartbeat/election tuning | etcd tolerates the hop between datacentres without election storms | a longer election timeout means a longer stall when a leader genuinely dies |
+
+`docs/variant-delta.md` is the exact diff. `docs/cost-comparison.md` has the measured
+prices behind the numbers above.
+
+## The decision this variant asks you to make
+
+`secondary_location` defaults to a datacentre in the same country as `primary_location`,
+not a distant one, and that is the interesting choice in the whole design.
+
+Geographic separation and etcd performance pull in opposite directions. A second site
+across the continent survives a regional event; it also puts tens of milliseconds between
+etcd members, and every write that needs the third member pays it. Get the heartbeat and
+election timeouts wrong for that distance and the failure is not a crash — it is a leader
+election storm, where members declare the leader dead over a late heartbeat, elect a new
+one, and repeat, while the API stalls for seconds at a time and nothing looks broken.
+
+The default trades regional survivability for single-digit latency: a different building,
+different power, different network, a few milliseconds away. **Measure your own
+round-trip time before choosing differently**, and raise the `etcd-arg` values in
+`main.tf` to match if you do.
+
+## Prerequisites and build
+
+Identical to `variants/solo` — same tools, same accounts, same two-pass build for the
+tailnet address (`docs/RUNBOOK.md` §2). Only the two location inputs are extra, and both
+have defaults:
 
 ```bash
-# 1. Inputs. Every variable without a default must be set — there are 25 of them, and
-#    the identifiers among them deliberately have no defaults so that a fork cannot
-#    inherit somebody else's domain, bucket or GitHub team.
-cp secrets.auto.example.tfvars secrets.auto.tfvars
-chmod 600 secrets.auto.tfvars
-$EDITOR secrets.auto.tfvars
-
-# 2. Which state store to use. providers.tf declares a PARTIAL backend and names no
-#    bucket, so init fails until you say. Create the bucket first, with versioning.
+cp secrets.auto.example.tfvars secrets.auto.tfvars && chmod 600 secrets.auto.tfvars
 cp backend.hcl.example backend.hcl
-$EDITOR backend.hcl
-
-# 3. The GitHub App private key, at the path named in secrets.auto.tfvars.
-cp ~/Downloads/your-app.private-key.pem secrets/your-github-app.pem
-chmod 600 secrets/your-github-app.pem
-
-# 4. An ssh-agent holding the private half of ssh_public_key_path. The key is
-#    deliberately never given to Terraform — it would be written into the state in
-#    cleartext — so provisioners get it from the agent instead.
+$EDITOR secrets.auto.tfvars backend.hcl
 eval "$(ssh-agent -s)" && ssh-add <the private half of ssh_public_key_path>
-
-# 5. Build.
 bash init.sh
 ```
 
-### The build takes two passes, and the first one looks like a failure
-
-`kube_api_tailnet_address` is the control plane's address on your tailnet. Tailscale
-assigns it when the node first joins, so on a cluster that does not exist yet **you
-cannot know it in advance** — and it is required in the API server's certificate.
+> **Use a different `key` in `backend.hcl` from any other cluster.** Two clusters sharing
+> a state key will fight over it and destroy each other's resources. The backend is
+> partial precisely so this is a decision you make rather than inherit.
 
-Set a placeholder inside `100.64.0.0/10`, leave
-`control_plane_lb_enable_public_interface = true` in `main.tf`, run `init.sh`, then read
-the assigned address, put it in `secrets.auto.tfvars`, set the flag to `false`, and
-`terraform apply` again. Full procedure with the reasoning: **`docs/RUNBOOK.md` §2.**
+### Extra step: verify quorum before you trust it
 
-Skipping this is why a green-field build fails on the first apply.
-
-## Day two
+Three control planes that never formed a quorum look exactly like three control planes
+that did, until the first failure. After the build:
 
 ```bash
-terraform init -backend-config=backend.hcl
-terraform plan     # read it. it is the only review that catches silent drift
-terraform apply
+kubectl get nodes -l node-role.kubernetes.io/control-plane
+# expect 3, all Ready, across two locations
+
+kubectl -n kube-system exec -it <a control-plane pod> -- \
+  etcdctl endpoint status --cluster -w table
+# expect 3 members, exactly one leader, and RAFT INDEX values within a few of each other
 ```
 
-`bash apply.sh` is the same thing with Packer and the phased apply skipped.
+A member that is persistently behind on raft index is a member that will not save you.
+
+## What this variant still does not give you
+
+Fewer than `solo`, but the list is not empty, and every item is structural rather than an
+omission:
 
-Two things in this configuration are hashed into Terraform state, so **editing a comment
-is not always free**: the `helm_release` values block (comments inside it are chart
-values) and anything under `extra-manifests/` or `scripts/` that is fingerprinted. A
-`plan` after a comment-only edit may legitimately show work. That is the mechanism doing
-its job — it exists so that editing a script actually deploys it.
-
-## Tearing down
-
-`destroy.sh` and `remove-protection.sh` both require `--project <name>`, prove the API
-token belongs to that project, default to a dry run, and demand a typed confirmation.
-`restore-protection.sh` puts delete protection back. Run them against a throwaway
-project only.
-
-## What this variant does not give you
-
-Stated plainly, because a reader coming from EKS/GKE/AKS will assume otherwise:
-
-- **No managed control-plane SLA** — there is nobody to page.
-- **No node auto-repair.** A NotReady node stays NotReady until a human acts.
-- **No drain headroom.** With two schedulable nodes there is nowhere to move pods to,
-  which is why `system_upgrade_use_drain = false`.
-- **A single NAT router** carrying all egress and the forwarded API port.
-- **etcd is yours.** Backups run; the restore is a manual procedure.
+- **No managed control-plane SLA.** Three control planes are three you maintain.
+- **No node auto-repair.** The autoscaler replaces nodes it manages; the static pools
+  have no health-driven replacement anywhere in kube-hetzner 2.19.2. A NotReady static
+  node stays NotReady until a human acts. Alert on it.
+- **Not true surge upgrades.** k3s' system-upgrade-controller never adds a node before
+  removing one, and a failed upgrade has no automatic rollback. Headroom emulates surge.
+- **No availability zones.** Hetzner has datacentres, not zones — a different, larger
+  latency domain than the ~1 ms zones managed Kubernetes spreads across.
+- **No workload identity.** Pods keep long-lived secrets.
+- **One cloud account** remains a single point of failure for everything in it.
 
-`docs/managed-k8s-parity.md` accounts for all of it, row by row, with what it would cost
-to close each gap.
+`docs/managed-k8s-parity.md` accounts for all twelve capabilities, including the six no
+self-hosted stack can match.
diff -ru -x .terraform -x .terraform.lock.hcl -x backend.hcl -x secrets.auto.tfvars -x '*.tfstate*' -x __pycache__ variants/solo/github.tf variants/ha/github.tf
--- variants/solo/github.tf
+++ variants/ha/github.tf
@@ -24,11 +24,11 @@
     environment = {
       # NAMED AFTER THE CLUSTER, not after "k3s". kube-hetzner writes
       # ${var.cluster_name}_kubeconfig.yaml (module kubeconfig.tf), and this line said
-      # k3s_kubeconfig.yaml until 2026-08-11 — correct here by coincidence, since this
-      # cluster is called k3s, and broken for every fork that picks another name. It
-      # surfaced the only way it could: the first green-field build, on a cluster named
-      # "gf", where the provisioner ran kubectl against a file that did not exist and
-      # fell back to localhost:8080. Nothing in production could ever have shown this.
+      # k3s_kubeconfig.yaml until 2026-08-11. It was correct only for a cluster that
+      # happens to be called k3s, and broken for every fork that picks another name. The
+      # first green-field build, on a cluster named "gf", is what found it: the
+      # provisioner ran kubectl against a file that did not exist and fell back to
+      # localhost:8080.
       KUBECONFIG                 = "${abspath(path.root)}/${var.cluster_name}_kubeconfig.yaml"
       GITHUB_APP_PEM_PATH        = "${abspath(path.root)}/${var.github_app_private_key_path}"
       GITHUB_APP_ID              = var.github_app_id
diff -ru -x .terraform -x .terraform.lock.hcl -x backend.hcl -x secrets.auto.tfvars -x '*.tfstate*' -x __pycache__ variants/solo/init.sh variants/ha/init.sh
--- variants/solo/init.sh
+++ variants/ha/init.sh
@@ -134,8 +134,8 @@
   echo "==> Day-2 apply: skipping Packer build and phased apply."
 
   # The module names this file after the cluster, not after "k3s" — see the note in
-  # github.tf. Hardcoding "k3s_kubeconfig.yaml" worked only because THIS cluster happens
-  # to be called k3s; a fork with any other cluster_name got a file it never looked at.
+  # github.tf. Hardcoding "k3s_kubeconfig.yaml" worked only for a cluster called k3s; a
+  # fork with any other cluster_name got a file it never looked at.
   KUBECONFIG_NAME="$(sed -n 's/^[[:space:]]*cluster_name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' secrets.auto.tfvars | head -1)_kubeconfig.yaml"
   if [ -f "${KUBECONFIG_NAME}" ]; then
     echo "==> Using existing ${KUBECONFIG_NAME}"
diff -ru -x .terraform -x .terraform.lock.hcl -x backend.hcl -x secrets.auto.tfvars -x '*.tfstate*' -x __pycache__ variants/solo/main.tf variants/ha/main.tf
--- variants/solo/main.tf
+++ variants/ha/main.tf
@@ -6,6 +6,37 @@
 # caution while the licence stays the project's own. The near-verbatim file is the Packer
 # template, and that one carries an MIT identifier. See ADR-0001 and ADR-0005.
 
+# ─────────────────────────────────────────────────────────────────────────────
+#  VARIANT: ha
+#
+#  The same architecture as variants/solo, at a different operating point. Read
+#  docs/variant-delta.md for the exact diff; this header is the intent behind it.
+#
+#  What changes, and what each change actually buys:
+#    3 control planes (2 + 1 across two locations) — losing one no longer stops
+#      scheduling, ArgoCD sync and every kubectl. You still operate etcd.
+#    3 general agents instead of 2 — enough capacity to EMPTY one, which is what
+#      makes a real drain possible. On 2026-08-05 the two-node variant cordoned a
+#      node for 2.5 hours with 8 pods Pending because there was nowhere to put them.
+#    system_upgrade_use_drain = true — reversing the solo mitigation, because the
+#      headroom above is the precondition that was missing.
+#    A redundant NAT router — in solo it is a single point of failure that takes
+#      SSH and the kube-API path with it.
+#    A cluster autoscaler with room to grow instead of a single spare node.
+#
+#  What it does NOT buy, stated here so nobody has to discover it:
+#    - No managed control-plane SLA. There is nobody to page.
+#    - No node auto-repair. A NotReady node stays NotReady until a human acts.
+#    - Hetzner has no availability zones inside a location, so "multi-location"
+#      here means multi-DATACENTRE — a different, larger latency domain than the
+#      zones EKS/GKE/AKS spread across. That is a trade, not an upgrade.
+#  docs/managed-k8s-parity.md has the full accounting.
+#
+#  NEVER APPLIED TO PRODUCTION by its authors. Its failure modes are proven only
+#  as far as the green-field build in the project's M4 phase proved them, and the
+#  README says which those are.
+# ─────────────────────────────────────────────────────────────────────────────
+
 locals {
   # kured ships tolerations for control-plane/master only; without the egress toleration it
   # never runs on the egress node, that node never reboots, and MicroOS transactional-update
@@ -104,9 +135,9 @@
   # EVERY nodepool names its OS, and green-field is the only build that can tell you why.
   #
   # 3.1.0 resolves an unset nodepool `os` through local.{control_plane,agent}_nodepool_default_os:
-  # a pool that already has servers keeps whatever those servers run (this cluster: microos),
-  # and a pool that does NOT yet exist gets "leapmicro". Production therefore saw no diff at
-  # all, and a green-field build failed at PLAN time on 2026-08-11:
+  # a pool that already has servers keeps whatever those servers run, and a pool that does
+  # NOT yet exist gets "leapmicro". An in-place upgrade therefore sees no diff at all, and a
+  # green-field build fails at PLAN time — measured on 2026-08-11 in the throwaway project:
   #
   #   Error: Resource not found
   #     with module.kube-hetzner.data.hcloud_image.leapmicro_x86_snapshot[0]
@@ -115,11 +146,10 @@
   #
   # packer/hcloud-microos-snapshots.pkr.hcl builds MicroOS and only MicroOS, so the snapshot
   # the module now looks for by default is one this repository never produces. Naming the OS
-  # makes the two agree, and makes the running cluster's OS a written fact rather than an
-  # inference from labels the module started writing in this same upgrade.
+  # makes the two agree.
   #
   # Moving to Leap Micro is the upstream recommendation for NEW clusters and is a separate
-  # decision: it needs a new Packer template and it cannot be proven against this cluster.
+  # decision: it needs a new Packer template.
   node_os = "microos"
 
   # ── Inputs that re-trigger the UPSTREAM kustomization ──────────────────────
@@ -142,19 +172,20 @@
   kured_version        = "1.21.0"
   cert_manager_version = "v1.20.3"
   traefik_version      = "41.0.0"
-  # Pinned during the 3.1.0 upgrade, at the version the cluster is ALREADY running
-  # (measured: `kubectl -n kube-system get ds cilium -o jsonpath=...` -> cilium:v1.17.0).
-  # It was inherited before: 2.19.2 defaulted to 1.17.0 and this file said nothing, so the
-  # module bump to 3.1.0 — whose default is 1.19.3 — would have carried the CNI across two
-  # minor versions inside a plan whose headline change was an input rename. That is the
-  # same silent-inheritance failure the note above describes, one layer down. Moving Cilium
-  # is a change with its own upgrade notes and its own blast radius; it gets its own PR.
-  cilium_version           = "1.17.0"
-  cilium_merge_values      = <<-EOT
+  # Pinned during the 3.1.0 upgrade, at the version 2.19.2 defaulted to. It was inherited
+  # before, so the module bump — whose default is 1.19.3 — would have carried the CNI
+  # across two minor versions inside a plan whose headline change was an input rename.
+  # That is the same silent-inheritance failure the note above describes, one layer down.
+  # Moving Cilium is a change with its own upgrade notes and its own blast radius.
+  cilium_version      = "1.17.0"
+  cilium_merge_values = <<-EOT
 encryption:
   enabled: true
   type: wireguard
   EOT
+  # HCLOUD_LOAD_BALANCERS_LOCATION must equal load_balancer_location below. If they
+  # disagree, the CCM provisions Service-type LoadBalancers in a different datacentre from
+  # the nodes they front, and every request pays a cross-site hop that nothing reports.
   hetzner_ccm_merge_values = <<-EOT
 env:
   HCLOUD_LOAD_BALANCERS_USE_PRIVATE_IP:
@@ -162,7 +193,7 @@
   HCLOUD_LOAD_BALANCERS_DISABLE_PRIVATE_INGRESS:
     value: "true"
   HCLOUD_LOAD_BALANCERS_LOCATION:
-    value: "nbg1"
+    value: "${var.primary_location}"
   EOT
   longhorn_merge_values    = <<-EOT
 defaultSettings:
@@ -207,8 +238,8 @@
   #
   # 3.1.0 renamed the MODULE INPUT to k3s_channel and changed its default from "v1.33" to
   # "stable" — so the value below stopped being a no-op the moment the module moved, and
-  # is now the only thing keeping this cluster on v1.33. The LOCAL deliberately keeps the
-  # v2 name: it is also a key in local.kustomization_trigger_fingerprint, and that
+  # is now the only thing holding a minor version. The LOCAL deliberately keeps the v2
+  # name: it is also a key in local.kustomization_trigger_fingerprint, and that
   # fingerprint is a sha1 over the JSON, key names included. Renaming the key would change
   # the hash and re-run the kured/storageclass patch hook for no reason at all.
   initial_k3s_channel = "v1.33"
@@ -267,13 +298,24 @@
       - level: Metadata
   EOT
 
+  # max_nodes is a COST CEILING, not a capacity wish. min_nodes = 0 means the idle bill is
+  # unchanged, but an autoscaler with no upper bound has an unbounded monthly cost, and
+  # "it only scales when it needs to" is not a budget.
+  #
+  # The arithmetic, from measured Hetzner prices (see docs/managed-k8s-parity.md):
+  # this variant idles at roughly 1.40x the solo variant. A cx33 is about EUR 10.27/month
+  # gross, so every point of max_nodes adds up to 0.13x. Three is 1.81x worst case. The
+  # project's own stop condition is 2.5x, which is reached at max_nodes = 8 — so eight is
+  # a hard ceiling with a reason behind it, not a round number.
+  #
+  # Raise it only together with the budget line it consumes.
   autoscaler_nodepools = [
     {
       name        = "autoscaled"
       server_type = "cx33"
-      location    = "nbg1"
+      location    = var.primary_location
       min_nodes   = 0
-      max_nodes   = 1
+      max_nodes   = 3
       os          = local.node_os
       labels = {
         "node.kubernetes.io/role" = "autoscaled"
@@ -349,38 +391,30 @@
   #     which provider 1.60.1 still REQUIRES." Moot rather than fixed: 3.1.0 declares
   #     hcloud >= 1.62.0, so 1.60.1 cannot be installed against it at all —
   #     `terraform init` exits 1 with "no available releases match the given constraints
-  #     1.60.1, >= 1.62.0". Against the provider now locked (1.68.0) the argument's absence
-  #     is a non-event: both nat_router primary IPs are refreshed and appear in NO change
-  #     list in the 3.1.0 plan.
-  #
-  #  2. "2.19.3 added trimspace(var.ssh_public_key); our state holds the key WITH a
-  #     trailing newline, so trimspace creates a phantom hcloud_ssh_key diff that cascades
-  #     into rebuilding the NAT router." Half true. The trimspace is still there in 3.1.0
-  #     and the phantom diff is REAL — the Hetzner API itself returns 108 bytes ending in
-  #     \n for ssh_key 111717378, so the trimmed config can never match the refreshed
-  #     state and hcloud_ssh_key.k3s[0] is replaced. The CASCADE is gone: 3.1.0 added
-  #     ssh_keys and user_data to hcloud_server.nat_router's ignore_changes, so the router
-  #     is updated in place (labels) and every other server is untouched. A replaced SSH
-  #     key object costs nothing at runtime — Hetzner consumes ssh_keys only at server
-  #     creation, and all five servers ignore that attribute.
-  #
-  # The upgrade happened because 2.19.2 declared `data "hcloud_image" "microos_arm_snapshot"`
-  # with no count — see enabled_architectures below for why that made a green-field build
-  # impossible while Hetzner's ARM fleet was sold out.
+  #     1.60.1, >= 1.62.0".
+  #
+  #  2. "2.19.3 added trimspace(var.ssh_public_key), which creates a phantom
+  #     hcloud_ssh_key diff that cascades into rebuilding the NAT router." Half true. The
+  #     trimspace is still there in 3.1.0, and the Hetzner API returns the stored key WITH
+  #     its trailing newline, so a state written before this upgrade can never match the
+  #     trimmed config and the key object is replaced once. The CASCADE is gone: 3.1.0
+  #     added ssh_keys and user_data to hcloud_server.nat_router's ignore_changes. A
+  #     replaced SSH key object costs nothing at runtime — Hetzner consumes ssh_keys only
+  #     at server creation, and every server ignores that attribute.
   version = "3.1.0"
 
   # THE REASON THIS MODULE WAS UPGRADED AT ALL, in one input.
   #
-  # Every node here is x86 (cx23/cx33). 2.19.2 did not care: it declared
-  # `data "hcloud_image" "microos_arm_snapshot"` with no count, so Terraform read the ARM
+  # Every node in this variant is x86. 2.19.2 did not care: it declared
+  # `data "hcloud_image" "microos_arm_snapshot"` with no count, so Terraform read an ARM
   # snapshot on EVERY plan, x86-only cluster or not — and the singular data source errors
-  # when nothing matches. That is survivable for this cluster because its ARM snapshot has
-  # existed since 2026-03-08. It is fatal for a green-field build: on 2026-08-10 all four
-  # cax types were unavailable in nbg1-dc3, hel1-dc2 and fsn1-dc14 (measured via GET
-  # /v1/datacenters), so no ARM snapshot could be created, so M4-b could not even PLAN.
+  # when nothing matches. That is survivable for a cluster whose ARM snapshot already
+  # exists, and fatal for a green-field build: when Hetzner's ARM fleet is sold out in
+  # your locations (measured 2026-08-10 across three datacentres), no ARM snapshot can be
+  # created, so `terraform plan` fails before a single resource exists.
   #
-  # 3.1.0 gates the lookup twice over: the data source is plural (`hcloud_images`, empty
-  # list instead of an error) and carries
+  # 3.1.0 gates the lookup twice over: the data source is plural (`hcloud_images`, an
+  # empty list instead of an error) and carries
   #   count = contains(var.enabled_architectures, "arm") && local.os_arch_requirements.microos.arm && ...
   # Naming x86 here closes the first clause explicitly rather than relying on the second.
   enabled_architectures = ["x86"]
@@ -410,14 +444,12 @@
   # days here, set 2026-08-05) rather than versioning kept forever.
   ssh_private_key = null
 
-  # Named explicitly rather than inherited. The value is the module's own default, so this
-  # changes nothing today — and that is the point: the name is currently INHERITED, so a
-  # module bump that changed the default would rename every resource in the project with
-  # no diff here to show it. Same reasoning as initial_k3s_channel above.
+  # Named explicitly rather than inherited. Set this to something distinct: this variant
+  # is the one people run alongside another cluster, and two projects both containing a
+  # cluster called "k3s" produce two identical sets of resource names.
   #
   # Not part of the kustomization trigger set — verified against the module: cluster_name
-  # feeds only a local backup filename, none of the helm values locals. So it needs no
-  # entry in local.kustomization_trigger_fingerprint.
+  # feeds only a local backup filename, none of the helm values locals.
   cluster_name = var.cluster_name
 
   network_region = "eu-central"
@@ -480,11 +512,35 @@
     }
   }
 
+  # Three control planes, split 2 + 1 across two locations.
+  #
+  # WHY THREE AND NOT TWO. etcd needs a strict majority to accept writes. Two members
+  # have a majority of two, so losing either one stops the API — two control planes are
+  # strictly worse than one, because there are twice as many things that can fail and no
+  # tolerance for either. Three tolerates one loss. Four tolerates one loss and costs more.
+  #
+  # WHY 2 + 1 AND NOT 1 + 1 + 1. With one member per location, losing the location holding
+  # a member costs you a third of the quorum and you survive. That sounds better, and for
+  # etcd it is worse: every write must be acknowledged by a majority, so with members
+  # spread evenly across three sites every single write crosses the network twice. With
+  # 2 + 1 the majority can be formed entirely inside the primary location, so the common
+  # case never leaves it — and losing the primary location still costs you the cluster,
+  # which is the honest trade being made here.
+  #
+  # WHAT THIS DOES NOT SURVIVE: losing var.primary_location. Two of three members live
+  # there. If surviving the loss of an entire datacentre is the requirement, this topology
+  # is the wrong one and no amount of tuning fixes it — that needs 1 + 1 + 1 and an
+  # acceptance of per-write cross-site latency.
+  #
+  # The third member gets its OWN placement group. A spread placement group guarantees
+  # different physical hosts within a location; across locations the guarantee is already
+  # implied and Hetzner has no reason to honour one group in two datacentres. Sharing a
+  # group would be, at best, a request that means nothing.
   control_plane_nodepools = [
     {
-      name        = "control-plane-nbg1-1",
+      name        = "control-plane-1",
       server_type = "cx23",
-      location    = "nbg1",
+      location    = var.primary_location,
       labels      = [],
       taints      = [],
       count       = 1
@@ -495,12 +551,12 @@
       enable_public_ipv6 = false
     },
     {
-      name        = "control-plane-nbg1-2",
+      name        = "control-plane-2",
       server_type = "cx23",
-      location    = "nbg1",
+      location    = var.primary_location,
       labels      = [],
       taints      = [],
-      count       = 0
+      count       = 1
 
       os = local.node_os
 
@@ -508,12 +564,15 @@
       enable_public_ipv6 = false
     },
     {
-      name        = "control-plane-hel1",
+      name        = "control-plane-3",
       server_type = "cx23",
-      location    = "hel1",
+      location    = var.secondary_location,
       labels      = [],
       taints      = [],
-      count       = 0
+      count       = 1
+
+      # Its own spread group — see the note above.
+      placement_group = "secondary"
 
       os = local.node_os
 
@@ -528,7 +587,7 @@
       # Resized cx23(4GB)→cx33(8GB) 2026-06-13: the DB node (6 postgres + keycloak-pg +
       # redis, all 7 hcloud-volumes attach here) was memory-bound at ~85%. cx33 doubles RAM.
       server_type = "cx33",
-      location    = "nbg1",
+      location    = var.primary_location,
       labels      = [],
       taints      = [],
       count       = 1
@@ -559,7 +618,7 @@
     {
       name        = "agent-large",
       server_type = "cx33",
-      location    = "nbg1",
+      location    = var.primary_location,
       labels      = [],
       taints      = [],
       count       = 1
@@ -579,9 +638,35 @@
       enable_public_ipv6 = false
     },
     {
+      # THE THIRD GENERAL AGENT — the reason system_upgrade_use_drain can be true below.
+      #
+      # Two schedulable nodes cannot be reduced to one without somewhere for the pods to
+      # go, so "drain a node" was not an operation the solo variant could perform. Adding
+      # a third is not about total capacity; it is about being able to empty one. Sized
+      # identically to agent-large so any pod that fits there fits here.
+      name        = "agent-large-2",
+      server_type = "cx33",
+      location    = var.primary_location,
+      labels      = [],
+      taints      = [],
+      count       = 1
+
+      kubelet_args = [
+        "kube-reserved=cpu=100m,memory=256Mi,ephemeral-storage=2Gi",
+        "system-reserved=cpu=200m,memory=256Mi,ephemeral-storage=2Gi",
+        "eviction-hard=memory.available<200Mi,nodefs.available<10%,imagefs.available<10%",
+        "enforce-node-allocatable=pods",
+      ]
+
+      os = local.node_os
+
+      enable_public_ipv4 = false
+      enable_public_ipv6 = false
+    },
+    {
       name        = "storage",
       server_type = "cx33",
-      location    = "nbg1",
+      location    = var.primary_location,
       labels = [
         "node.kubernetes.io/server-usage=storage"
       ],
@@ -602,7 +687,7 @@
     {
       name        = "egress",
       server_type = "cx23",
-      location    = "nbg1",
+      location    = var.primary_location,
       labels = [
         "node.kubernetes.io/role=egress"
       ],
@@ -631,7 +716,7 @@
       # inserting a pool earlier re-indexes (and recreates) the egress node.
       name        = "agent-ci",
       server_type = "cx33",
-      location    = "nbg1",
+      location    = var.primary_location,
       labels = [
         "node.kubernetes.io/role=ci"
       ],
@@ -657,15 +742,36 @@
   ]
 
   load_balancer_type     = "lb11"
-  load_balancer_location = "nbg1"
+  load_balancer_location = var.primary_location
 
+  # Redundant NAT router. In the solo variant this is one server, and it is the most
+  # consequential single point of failure in that design: it carries ALL egress, and with
+  # control_plane_lb_enable_public_interface = false it also carries the forwarded kube-API
+  # port. Losing it takes out cluster egress and the SSH path at the same time, which is
+  # also the path you would use to fix it.
+  #
+  # With redundancy the module builds two routers with a keepalived VIP and puts the
+  # standby in standby_location, so the pair does not share a datacentre.
+  #
+  # CONSEQUENCE WORTH KNOWING BEFORE YOU NEED IT: after a failover, egress leaves from the
+  # standby's location and therefore from a DIFFERENT public IP. Anything that allowlists
+  # this cluster's egress address by IP — a payment provider, a partner API, a database
+  # firewall — must allowlist both addresses, or the failover trades an outage for a
+  # subtler one. Both primary IPs are stable resources, so both are knowable up front.
   nat_router = {
     server_type       = "cx23"
-    location          = "nbg1"
+    location          = var.primary_location
     enable_sudo       = false
-    enable_redundancy = false # set true + standby_location for HA
+    enable_redundancy = true
+    standby_location  = var.secondary_location
   }
 
+  # Redundancy is not free of credentials: the keepalived pair moves the floating IP by
+  # calling the Hetzner API, so a token lives ON the routers — the only hosts here with a
+  # public interface. Use a SEPARATE token from hcloud_token so it can be revoked on its
+  # own. See variable "nat_router_hcloud_token".
+  nat_router_hcloud_token = var.nat_router_hcloud_token
+
   enable_delete_protection = {
     floating_ip   = true
     load_balancer = true
@@ -718,31 +824,28 @@
 
   automatically_upgrade_kubernetes = true
 
-  # false = cordon during a k3s upgrade, do not drain. This is a small-cluster setting
-  # and it comes from an incident on 2026-08-05.
-  #
-  # With true, the system-upgrade-controller tries to move every pod off a node before
-  # upgrading it. A cluster this size cannot do that: only TWO nodes accept general
-  # workloads (the control plane, CI and egress pools are all tainted), and the other one
-  # runs at around 93% memory. The 17 pods on the node being upgraded did not fit, so the
-  # drain never completed, the upgrade job hit its deadline (DeadlineExceeded), and the
-  # node was left CORDONED — for 150 minutes, with 8 pods Pending. One of those pods was
-  # Alertmanager, which is why no alert fired about any of it.
-  #
-  # The module documents this on system_upgrade_enable_eviction: "Disable this on small
-  # clusters to avoid system upgrades hanging since pods resisting eviction keep node
-  # unschedulable forever."
-  #
-  # With false the node keeps running through the upgrade: cordon -> update k3s in place
-  # -> uncordon. Pods experience an agent restart instead of a migration, which is not a
-  # new class of disruption here — kured already runs with --drain-timeout=5m
-  # --force-reboot=true and stops those same pods every night.
-  #
-  # This is a mitigation, not a fix. The fix is enough capacity to empty a node: a third
-  # worker, either static or via the autoscaler configured below. NEVER delete the
-  # zero-count pool above to make room in the list — agent pools are keyed by index, and
-  # removing one rebuilds every pool after it.
-  system_upgrade_use_drain = false
+  # true = actually move pods off a node before upgrading it. The solo variant sets this
+  # to FALSE, and that difference is the single clearest illustration of what this variant
+  # is for.
+  #
+  # Why solo has to say false: with only two nodes accepting general workloads, a drain
+  # has nowhere to put the evicted pods. On 2026-08-05 that left a node cordoned for 150
+  # minutes with 8 pods Pending — one of them Alertmanager, which is why nothing alerted.
+  # The module warns about exactly this on system_upgrade_enable_eviction: "Disable this
+  # on small clusters to avoid system upgrades hanging since pods resisting eviction keep
+  # node unschedulable forever."
+  #
+  # Why this variant can say true: three general agents plus an autoscaler pool. Emptying
+  # one leaves two, and Pending pods bring up a fourth in under three minutes (measured).
+  #
+  # THE PRECONDITION IS CAPACITY, NOT THIS FLAG. Setting true on a cluster whose remaining
+  # nodes cannot absorb the evicted pods reproduces the 2026-08-05 incident exactly. If
+  # you shrink the agent pools below, change this back to false in the same commit.
+  #
+  # Still not surge: k3s' system-upgrade-controller never adds a node before removing one,
+  # and a failed upgrade has no automatic rollback. Headroom emulates surge; it does not
+  # implement it, and the runbook must cover manual recovery.
+  system_upgrade_use_drain = true
 
   system_upgrade_schedule_window = local.system_upgrade_schedule_window
   k3s_channel                    = local.initial_k3s_channel
@@ -800,6 +903,25 @@
   control_planes_custom_config = {
     etcd-snapshot-schedule-cron = "0 */4 * * *"
     etcd-snapshot-retention     = 42
+
+    # etcd across two datacentres. The defaults (100 ms heartbeat, 1000 ms election
+    # timeout) assume members share a LAN. They do not here, and etcd's failure mode when
+    # they are too tight is not a crash: it is a leader election storm — members declare
+    # the leader dead because a heartbeat was late, elect a new one, and repeat. The API
+    # then stalls for seconds at a time with nothing obviously broken.
+    #
+    # etcd's own guidance is heartbeat >= round-trip time and election timeout at least
+    # 10x heartbeat. The values below are sized for a same-country hop, which is why
+    # var.secondary_location defaults to a nearby datacentre rather than a distant one.
+    #
+    # THESE NUMBERS ARE NOT UNIVERSAL. Measure the actual RTT between your two locations
+    # and raise them if it exceeds ~30 ms; a longer election timeout also means a longer
+    # outage when a leader genuinely dies, so this is a trade to make deliberately and not
+    # a value to inflate for safety.
+    etcd-arg = [
+      "heartbeat-interval=250",
+      "election-timeout=2500",
+    ]
   }
 
   # Not in local.kustomization_trigger_fingerprint on purpose: this input drives
@@ -807,13 +929,33 @@
   # it in the fingerprint would re-run the kured patch for no reason.
   audit_policy_config = local.k3s_audit_policy
 
+  # ── Cluster access identity: deliberately NOT configured ────────────────────
+  #
+  # Managed Kubernetes maps cloud IAM identities to RBAC, so access is per-person,
+  # auditable and revocable. Here, access is a static client certificate in the kubeconfig:
+  # no per-user identity, and no revocation short of rotating the CA.
+  #
+  # kube-hetzner 2.19.2 exposes `authentication_config` (k3s structured authentication),
+  # so wiring an external OIDC provider is a supported one-liner:
+  #
+  #   authentication_config = file("${path.module}/authentication-config.yaml")
+  #
+  # It is left off on purpose, and the reason is a bootstrap circularity worth
+  # understanding before you turn it on: if the identity provider runs INSIDE this
+  # cluster, then losing the cluster loses the way to log in and fix it. If you enable
+  # OIDC, either host the IdP elsewhere or keep the certificate kubeconfig as a
+  # break-glass credential — which means keeping the revocation problem you were trying
+  # to solve, for one account.
+  #
+  # Workload identity (IRSA / GKE WI / AKS managed identity) has no equivalent at all.
+  # Pods here keep long-lived secrets. That is structural, not an omission.
+
   automatically_upgrade_os = true
   #
-  # Runs on every node after the k3s install command. This is what makes a REBUILT control
-  # plane safe: it arrives with the skip already in place, so it never re-applies the addon
-  # and never resets the annotation. Changing this changes cloud-init, which the module puts
-  # in ignore_changes (modules/host/main.tf) — so it does NOT rebuild running nodes; it only
-  # takes effect on new ones, which is precisely the set of nodes that need it.
+  # Runs on every node after the k3s install command. In this variant that matters more
+  # than in solo: there are THREE control planes, each with its own manifests directory and
+  # its own deploy controller, so a skip file placed only on the first one leaves two nodes
+  # able to reset the annotation. Every node gets it here.
   postinstall_exec = [
     local.local_storage_skip_cmd,
   ]
@@ -871,15 +1013,11 @@
   # (ping blocked). Same literal `false` in both, opposite meaning — so saying nothing here
   # would have silently dropped the firewall's ICMP rule during a version bump.
   #
-  # true keeps today's behaviour. Measured before choosing: three ICMP echoes to the NAT
-  # router's public IPv4 (read out of state, not written down here) answered, 0% loss —
-  #   terraform state show 'module.kube-hetzner.hcloud_primary_ip.nat_router_primary_ipv4[0]'
-  # is where that address comes from. Every node has enable_public_ipv4 =
-  # false, so that router is the ONLY address this rule applies to — and with the API on a
-  # tailnet, an ICMP echo to it is the one liveness check that still works from outside when
-  # the tailnet itself is the thing that is broken. docs/ARCHITECTURE.md names the missing
-  # break-glass path as a known cost of the tailnet posture; this is not the change that
-  # should quietly make it worse. Blocking it is a defensible hardening step — as its own PR.
+  # true keeps the 2.19.2 behaviour. Every node sets enable_public_ipv4 = false, so the NAT
+  # router is the only address this rule applies to — and with the API on a VPN, an ICMP
+  # echo to it is the one liveness check that still works from outside when the VPN itself
+  # is the thing that is broken. Blocking it is a defensible hardening step, but it is a
+  # posture decision and belongs in a change that is about posture.
   allow_inbound_icmp = true
 
   cni_plugin = "cilium"
@@ -887,26 +1025,14 @@
   # NOT a straight rename of 2.19.2's disable_kube_proxy, and the difference is the whole
   # point. 2.19.2 hardcoded `kubeProxyReplacement: true` and `bpf.masquerade: true` in the
   # Cilium values NO MATTER what disable_kube_proxy said; that flag only decided whether
-  # k3s ALSO started its own embedded kube-proxy. We never set it, so this cluster has been
-  # running both: Cilium replacing kube-proxy, and k3s starting one anyway.
+  # k3s ALSO started its own embedded kube-proxy, and the default left one running.
   #
   # 3.1.0 ties the Cilium values to this input — `kubeProxyReplacement: ${!enable_kube_proxy}`
   # and `bpf.masquerade: ${!enable_kube_proxy}` — so the literal translation of the old
-  # default (enable_kube_proxy = true) would flip BOTH of those to false and tear out the
-  # dataplane this cluster actually runs. Measured on the live cluster before choosing:
-  #
-  #   kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.kube-proxy-replacement}'
-  #     -> true
-  #   ... '{.data.enable-bpf-masquerade}'   -> true
-  #
-  # false is therefore the value that keeps Cilium exactly as deployed. It is also the only
-  # value 3.1.0 accepts here at all: validation-contract.tf:1112 fails the plan outright
-  # because cilium_egress_gateway_enabled requires kube-proxy replacement, and that egress
-  # gateway is what pins outbound traffic to the dedicated egress node's IP.
-  #
-  # WHAT IT CHANGES ON THE NEXT APPLY: k3s stops starting the redundant embedded kube-proxy
-  # (`disable-kube-proxy: true` lands in config.yaml). Cilium has been serving that role
-  # since the cluster was built, so this removes a duplicate, not the implementation.
+  # default (true) flips both to false and changes the dataplane rather than preserving it.
+  # false is the value that reproduces what 2.19.2 deployed, and it is also the only value
+  # 3.1.0 accepts here at all: validation-contract.tf:1112 fails the plan outright because
+  # cilium_egress_gateway_enabled requires kube-proxy replacement.
   enable_kube_proxy = false
 
   cilium_version = local.cilium_version
@@ -932,18 +1058,12 @@
   #
   # BOOTSTRAP ORDER, for a cluster that does not exist yet: the address is assigned by
   # Tailscale when the control plane first joins the tailnet, so it cannot be known in
-  # advance. Build in two passes — see var.bootstrap_phase and docs/RUNBOOK.md:
-  #   1. terraform apply -var bootstrap_phase=true — no tailnet SAN, and the control-plane
-  #      LB keeps its public interface so the apply can reach the API at all;
-  #   2. read the assigned address, set kube_api_tailnet_address, apply again. The cert is
-  #      reissued with the new SAN and the public interface closes.
-  #
-  # THE FLAG IS NEW AND THE REASON IS EMBARRASSING. This comment described those two
-  # passes for months while the configuration made them impossible: the variable had no
-  # default, so "apply with it unset" is something Terraform refuses before it plans, and
-  # the public interface below was hardcoded false. The first green-field build ever
-  # attempted stopped here, at plan time. Documentation that has never been executed is a
-  # hypothesis.
+  # advance. Build in two passes — see docs/RUNBOOK.md:
+  #   1. apply with var.kube_api_tailnet_address unset and the public LB interface still
+  #      enabled, so the node can come up and register with Tailscale;
+  #   2. read the assigned address, set the variable, apply again. The cert is reissued
+  #      with the new SAN and the public interface can then be closed.
+  # Skipping pass 1 is why a green-field build used to fail outright on this line.
   additional_tls_sans       = var.bootstrap_phase ? [] : [var.kube_api_tailnet_address]
   kubeconfig_server_address = var.bootstrap_phase ? "" : var.kube_api_tailnet_address
 
@@ -953,14 +1073,9 @@
   # NAT-router rebuild (public IP preserved via the stable primary-IP resource; kubectl over
   # the tailnet is unaffected). The resulting 6443 forward on the NAT router's public IP is
   # firewall-gated to firewall_kube_api_source (100.64.0.0/10), so it is not publicly reachable.
-  #
-  # Open ONLY during pass 1 of a green-field build (var.bootstrap_phase), because that
-  # apply has to reach an API whose tailnet address does not exist yet. Closed for every
-  # apply after it, which is what the default false means: an operator who never thinks
-  # about this flag gets the closed state.
-  #
-  # 3.1.0 renamed this input to control_plane_load_balancer_enable_public_network. Same
-  # meaning, same polarity — unlike allow_inbound_icmp and enable_kube_proxy above.
+  # Open ONLY during pass 1 of a green-field build (var.bootstrap_phase); closed for
+  # every apply after it. The default false means an operator who never thinks about
+  # this flag gets the closed state.
   control_plane_load_balancer_enable_public_network = var.bootstrap_phase
 
   cilium_merge_values = local.cilium_merge_values
diff -ru -x .terraform -x .terraform.lock.hcl -x backend.hcl -x secrets.auto.tfvars -x '*.tfstate*' -x __pycache__ variants/solo/secrets.auto.example.tfvars variants/ha/secrets.auto.example.tfvars
--- variants/solo/secrets.auto.example.tfvars
+++ variants/ha/secrets.auto.example.tfvars
@@ -81,6 +81,14 @@
 etcd_s3_bucket     = "k3s-etcd-snapshots"
 etcd_s3_region     = "<your-s3-bucket-region>"
 
+# ─── Locations (this variant only) ───────────────────────────────────────────
+# Both have defaults, so you can leave them out. Read the descriptions in variables.tf
+# before you change secondary_location: it is where the third etcd member lives, and the
+# distance between the two locations is paid on writes.
+#
+# primary_location   = "nbg1"   # two control planes, all agents, both LBs, active NAT
+# secondary_location = "fsn1"   # third control plane, standby NAT router
+
 # Firewall sources. Both are required and neither may be null — null used to be the
 # value shipped here, and it disabled the restriction entirely while still passing the
 # old validation. The values below are a working, safe default: the Kubernetes API is
@@ -92,6 +100,13 @@
 firewall_kube_api_source = ["100.64.0.0/10"] # Tailscale CGNAT range
 firewall_ssh_source      = ["203.0.113.7/32"] # REPLACE: your egress IP (this is TEST-NET-3, reserved for docs)
 
+# Required by this variant because the NAT routers are redundant: the keepalived pair
+# calls the Hetzner API to move the floating IP on failover, so this token is written onto
+# machines with a public interface. Use a SEPARATE token from hcloud_token above — not
+# because it is less powerful (Hetzner tokens cannot be scoped) but so it can be revoked
+# without taking the rest of the cluster's automation with it.
+nat_router_hcloud_token = "<a second 64-character Hetzner API token>"
+
 tailscale_auth_key = "<your-tailscale-auth-key>"
 
 # The control-plane node's tailnet address. Serves double duty: certificate SAN and the
diff -ru -x .terraform -x .terraform.lock.hcl -x backend.hcl -x secrets.auto.tfvars -x '*.tfstate*' -x __pycache__ variants/solo/variables.tf variants/ha/variables.tf
--- variants/solo/variables.tf
+++ variants/ha/variables.tf
@@ -61,57 +61,51 @@
   type        = string
 }
 
-variable "acme_server" {
-  description = <<-EOT
-    ACME directory URL for the ClusterIssuer.
-
-    Production:  https://acme-v02.api.letsencrypt.org/directory
-    Staging:     https://acme-staging-v02.api.letsencrypt.org/directory
-
-    DELIBERATELY NO DEFAULT, and this is the one place where "no default" is about safety
-    rather than identity. Either default is wrong in a way that is hard to see:
-
-      - defaulting to PRODUCTION means every experiment, every green-field test build and
-        every fork burns Let's Encrypt's real rate limits. They are per registered domain
-        and per week; exhausting them takes out certificate issuance for the domain, and
-        waiting is the only remedy.
-      - defaulting to STAGING means a forgotten line in a tfvars file silently gives a
-        production cluster untrusted certificates. Every browser and every client rejects
-        them, and the configuration looks entirely correct.
+# ─── Locations ───────────────────────────────────────────────────────────────
+# This variant is multi-location by design, so where things go is an input rather than a
+# constant repeated a dozen times. In the solo variant the location is a literal, because
+# there is only one and nothing has to agree with anything.
 
-    An unset variable is an error, which is neither of those.
+variable "primary_location" {
+  description = <<-EOT
+    Datacentre holding two of the three control planes, every agent, both load balancers
+    and the active NAT router. This is where the cluster really lives.
 
-    Changing this value on a live cluster makes cert-manager register a new ACME account
-    and reissue every certificate. Expect a burst of issuance, and do not do it casually
-    on production.
+    Must be inside network_region (main.tf) — "eu-central" covers the German and Finnish
+    locations, and mixing regions is not supported by the network the module builds.
   EOT
   type        = string
+  default     = "nbg1"
   nullable    = false
-
-  validation {
-    condition     = can(regex("^https://[a-z0-9.-]+/", var.acme_server))
-    error_message = "acme_server must be an https ACME directory URL, e.g. https://acme-staging-v02.api.letsencrypt.org/directory"
-  }
 }
 
-variable "cluster_name" {
+variable "secondary_location" {
   description = <<-EOT
-    Name of the cluster. Every server, load balancer, network, placement group and
-    firewall is named after it, so it is what you see in the cloud console.
+    Datacentre holding the third control plane and the standby NAT router.
 
-    The default matches the upstream module's, which keeps existing clusters unchanged.
-    Set it to something distinct for any cluster that is not your only one: two clusters
-    both called "k3s", in two projects, produce two identical sets of resource names — and
-    the only thing that then tells a human (or a script) which console they are looking at
-    is the project selector.
+    THE DEFAULT IS A DELIBERATE COMPROMISE, and the interesting decision in this variant.
+    A second datacentre in the same country is a few milliseconds away; one across the
+    continent is tens of milliseconds away. etcd pays that distance on every write that
+    needs the third member, and a leader election crossing it is where "the API froze for
+    ten seconds" comes from. Geographic separation buys blast-radius reduction and costs
+    latency, and the two pull in opposite directions.
+
+    The default picks a nearby datacentre: different building, different power, different
+    network, single-digit RTT. If your requirement is surviving a regional event rather
+    than a datacentre event, choose a distant location — and then RAISE the etcd
+    heartbeat and election timeouts in control_planes_custom_config to match the measured
+    round-trip time, or you will trade a rare outage for a frequent one.
+
+    Measure before you choose. This project's own green-field build measures the RTT under
+    etcd load and publishes the number rather than a recommendation.
   EOT
   type        = string
-  default     = "k3s"
+  default     = "fsn1"
   nullable    = false
 
   validation {
-    condition     = can(regex("^[a-z0-9-]+$", var.cluster_name))
-    error_message = "cluster_name must be lowercase alphanumeric characters and dashes only — it becomes part of every resource name."
+    condition     = var.secondary_location != var.primary_location
+    error_message = "secondary_location must differ from primary_location — otherwise the third control plane and the standby NAT router sit in the datacentre they exist to survive the loss of."
   }
 }
 
@@ -245,6 +239,60 @@
   }
 }
 
+variable "acme_server" {
+  description = <<-EOT
+    ACME directory URL for the ClusterIssuer.
+
+    Production:  https://acme-v02.api.letsencrypt.org/directory
+    Staging:     https://acme-staging-v02.api.letsencrypt.org/directory
+
+    DELIBERATELY NO DEFAULT, and this is the one place where "no default" is about safety
+    rather than identity. Either default is wrong in a way that is hard to see:
+
+      - defaulting to PRODUCTION means every experiment, every green-field test build and
+        every fork burns Let's Encrypt's real rate limits. They are per registered domain
+        and per week; exhausting them takes out certificate issuance for the domain, and
+        waiting is the only remedy.
+      - defaulting to STAGING means a forgotten line in a tfvars file silently gives a
+        production cluster untrusted certificates. Every browser and every client rejects
+        them, and the configuration looks entirely correct.
+
+    An unset variable is an error, which is neither of those.
+
+    Changing this value on a live cluster makes cert-manager register a new ACME account
+    and reissue every certificate. Expect a burst of issuance, and do not do it casually
+    on production.
+  EOT
+  type        = string
+  nullable    = false
+
+  validation {
+    condition     = can(regex("^https://[a-z0-9.-]+/", var.acme_server))
+    error_message = "acme_server must be an https ACME directory URL, e.g. https://acme-staging-v02.api.letsencrypt.org/directory"
+  }
+}
+
+variable "cluster_name" {
+  description = <<-EOT
+    Name of the cluster. Every server, load balancer, network, placement group and
+    firewall is named after it, so it is what you see in the cloud console.
+
+    The default matches the upstream module's, which keeps existing clusters unchanged.
+    Set it to something distinct for any cluster that is not your only one: two clusters
+    both called "k3s", in two projects, produce two identical sets of resource names — and
+    the only thing that then tells a human (or a script) which console they are looking at
+    is the project selector.
+  EOT
+  type        = string
+  default     = "k3s"
+  nullable    = false
+
+  validation {
+    condition     = can(regex("^[a-z0-9-]+$", var.cluster_name))
+    error_message = "cluster_name must be lowercase alphanumeric characters and dashes only — it becomes part of every resource name."
+  }
+}
+
 variable "utility_namespaces" {
   type        = list(string)
   description = "List of Kubernetes namespaces to create"
@@ -373,6 +421,32 @@
   }
 }
 
+variable "nat_router_hcloud_token" {
+  description = <<-EOT
+    Hetzner API token that the NAT routers themselves use to move the floating IP on
+    failover. Required whenever nat_router.enable_redundancy is true, which this variant
+    sets — the keepalived pair cannot reassign the address without calling the API.
+
+    GIVE IT ITS OWN TOKEN, not a copy of hcloud_token. This value is written onto the NAT
+    router VMs, which are the only machines in the cluster with a public interface and the
+    ones an attacker reaches first. Hetzner tokens cannot be scoped to a resource, so a
+    copy of the main token on that host is a full read-write project credential sitting on
+    the edge. A separate token is not less powerful — it is separately REVOCABLE, so
+    rotating it does not take the whole cluster's automation down with it.
+
+    Treat a compromise of this token as a compromise of the project, and rotate it on the
+    same schedule as any other edge credential.
+  EOT
+  type        = string
+  sensitive   = true
+  nullable    = false
+
+  validation {
+    condition     = length(var.nat_router_hcloud_token) == 64
+    error_message = "nat_router_hcloud_token must be a 64-character Hetzner API token. The provider rejects anything else, but only once it is already building — this catches it at plan time."
+  }
+}
+
 variable "tailscale_auth_key" {
   description = "Tailscale auth key for node registration"
   type        = string
```
