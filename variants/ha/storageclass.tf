# Exactly one StorageClass may be marked default. This cluster keeps ending up with two.
#
# hcloud-volumes (CSI, replicated, survives a node loss) is the intended default.
# local-path (k3s local-storage addon, node-local, LOST when the node dies) also marks
# itself default. With both marked, a PVC that omits storageClassName gets whichever the
# API server picks — and on 2026-07-03 that put invoicing-postgres on local-path.
#
# WHY A ONE-SHOT PATCH IS NOT ENOUGH, measured 2026-08-08:
# the annotation is owned by field manager "deploy@k3s-control-plane-...", i.e. k3s's addon
# deploy controller, which re-applies /var/lib/rancher/k3s/server/manifests/local-storage.yaml
# on every k3s START — not only on a version upgrade, as previously assumed. So ANY k3s
# restart resets it: a config change, a node reboot, a crash. The kustomize hook
# (local.storageclass_default_fix_cmd) repairs it at apply time and is still worth keeping,
# but it only runs when the hook is re-triggered, so between applies the cluster silently
# drifts back into the incident condition. That is exactly how it regressed after the
# 2026-07-03 fix, and again after the audit-logging restart on 2026-08-08.
#
# WHAT THIS RESOURCE BUYS: the annotation becomes DECLARED state. Terraform now owns it,
# so `terraform plan` reports the drift the moment k3s resets it, instead of nobody
# noticing until a PVC lands in the wrong place. That is the "post-apply assertion" the
# G1 audit asked for under P0-1.
#
# WHAT IT DOES NOT BUY: continuous reconciliation. Between a k3s restart and the next
# terraform run the cluster is still in the bad state. The durable fix is an in-cluster
# reconciler (a tiny controller or an ArgoCD-managed patch), which belongs in the GitOps
# repository, not here — see the follow-up note in the plan.
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
