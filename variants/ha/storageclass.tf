# SPDX-License-Identifier: Apache-2.0

# Exactly one StorageClass may be marked default. This cluster keeps ending up with two.
#
# hcloud-volumes (CSI, replicated, survives a node loss) is the intended default.
# local-path (k3s local-storage addon, node-local, LOST when the node dies) also marks
# itself default. With both marked, a PVC that omits storageClassName gets whichever the
# API server picks — and on 2026-07-03 that put invoicing-postgres on local-path.
#
# THE ROOT CAUSE IS NOW FIXED ELSEWHERE, AND THIS RESOURCE CHANGED JOB.
#
# The annotation used to be owned by field manager "deploy@k3s-control-plane-...", k3s's
# addon deploy controller, which re-applies its packaged local-storage manifest on every
# k3s START — not on version upgrades, as was assumed for a long time, but on every start.
# So any restart reset it: a config change, a node reboot, a crash. Measured most recently
# at 2026-08-09T01:21:26Z, inside kured's reboot window.
#
# That controller no longer manages local-path at all. main.tf drops a
# local-storage.yaml.skip file (both on running nodes and, via postinstall_exec, on every
# new one), and extra-manifests/local-path-provisioner.yaml.tpl is a vendored copy of the
# manifest with the annotation already "false". k3s' own maintainers recommend this shape
# of fix — see k3s-io/k3s#4083 and scripts/vendor-local-path.sh.
#
# SO WHAT IS THIS RESOURCE FOR NOW? It is an ASSERTION, not a repair. Nothing should ever
# change this annotation again, and if something does — a manual kubectl patch, a future
# k3s that ignores the skip, a re-enabled addon — `terraform plan` says so. It costs one
# API read per plan and it is the only thing that would notice.
#
# WHAT IT STILL DOES NOT BUY: continuous reconciliation. It reports at plan time, not in
# real time. Alerting on "the newest default StorageClass is not the CSI one" belongs in
# monitoring, and a class-less PVC submitted with --dry-run=server is the cheapest probe
# for it — that tests the outcome rather than the mechanism.
resource "kubernetes_annotations" "local_path_not_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "local-path"
  }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  # k3s's deploy controller owns this field; without force, Terraform refuses to take it.
  force         = true
  field_manager = "terraform-storageclass-default"
}

# ── Default StorageClass with reclaimPolicy: Retain ──────────────────────────
#
# Every dynamically provisioned volume in this cluster used to inherit
# reclaimPolicy: Delete from hcloud-volumes, including every production database. A
# `kubectl delete pvc`, a Helm uninstall or an ArgoCD prune therefore destroyed the data
# outright — no Released PV, nothing to re-bind. The ten existing database volumes were
# patched to Retain on 2026-08-08; this closes the gap for volumes created after that.
#
# WHY A NEW CLASS AND NOT A PATCH: reclaimPolicy is IMMUTABLE on an existing
# StorageClass, so hcloud-volumes cannot be changed in place. And patching it would not
# survive anyway — hcloud-volumes is created by the CSI chart, which re-applies it, the
# same way k3s's addon controller keeps resetting local-path's default annotation above.
# A Terraform-owned class is not touched by either.
#
# This class is made DEFAULT, and hcloud-volumes is demoted below. That is what actually
# closes the gap: a PVC that names no storageClassName now gets Retain automatically,
# with no change required in the GitOps repository. Workloads that want the old
# behaviour can still name hcloud-volumes explicitly.
#
# Spec mirrors hcloud-volumes exactly as measured (provisioner csi.hetzner.cloud,
# WaitForFirstConsumer, expansion allowed, no parameters) — only reclaimPolicy differs.
#
# OPERATIONAL CONSEQUENCE, so it is not a surprise: a Retained PV does not re-bind on its
# own. Delete and recreate a StatefulSet and the new PVC will not pick up the old volume
# until its spec.claimRef is cleared. Recovering a released volume is a five minute job;
# recovering deleted data is not.
resource "kubernetes_storage_class_v1" "hcloud_volumes_retain" {
  metadata {
    name = "hcloud-volumes-retain"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner    = "csi.hetzner.cloud"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
}

# Exactly one class may be default. Same reasoning and same mechanism as
# local_path_not_default above: the CSI chart owns hcloud-volumes and re-applies it, so
# Terraform declares the annotation and `terraform plan` surfaces the drift if it returns.
resource "kubernetes_annotations" "hcloud_volumes_not_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "hcloud-volumes"
  }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }
  force         = true
  field_manager = "terraform-storageclass-default"

  depends_on = [kubernetes_storage_class_v1.hcloud_volumes_retain]
}
