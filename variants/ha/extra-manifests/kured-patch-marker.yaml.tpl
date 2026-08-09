# Rendered by kube-hetzner's extra_kustomize mechanism (kustomization_user.tf).
# This marker exists for two reasons:
#  1. kustomization_user_deploy has count = (number of templates > 0) — without at least
#     one template in extra-manifests/, extra_kustomize_deployment_commands (which is
#     where the kured tolerations patch lives) would NEVER run at all.
#  2. The patch JSON is rendered into this ConfigMap via extra_kustomize_parameters,
#     so changing the patch in main.tf changes this template's sha1 and re-triggers
#     the deploy resource — the patch re-applies on the next terraform apply.
apiVersion: v1
kind: ConfigMap
metadata:
  name: terraform-extra-manifests
  namespace: kube-system
data:
  kured-tolerations-patch: '${kured_tolerations_patch}'
  # Tracks kured_options (main.tf), so changing the options re-triggers the patch hook
  # as well. Without it the upstream re-render silently drops the egress toleration —
  # which is what happened on 2026-06-13 when the reboot window was first set.
  kured-options-fingerprint: '${kured_options_fingerprint}'
  # Turns Longhorn scheduling off on the small agent node, which hosts no replicas.
  # A block scalar, not a quoted string: the command contains both quote characters.
  longhorn-small-no-sched: |
    ${longhorn_small_no_sched}
  # The double-default-StorageClass repair (2026-07-03): marks local-path not-default.
  # Kept in the marker so editing it re-triggers the deploy hook.
  storageclass-default-fix: |
    ${storageclass_default_fix}
  # Fingerprint of EVERY module input that re-triggers the upstream kustomization
  # (see local.kustomization_trigger_fingerprint). The line above covered only
  # kured_options, which was not enough: on 2026-08-05 pinning cert-manager and traefik
  # re-triggered the upstream kustomize apply, that wiped the kured tolerations, and this
  # marker did not change — so the patch hook never ran and the loss was invisible until
  # someone counted kured pods three days later.
  #
  # WATCH OUT: passing a value to extra_kustomize_parameters does NOTHING unless the
  # template actually consumes it. The first attempt at this fix was inert for exactly
  # that reason and the plan stayed empty. This line is what makes the fingerprint work.
  kustomization-trigger-fingerprint: '${kustomization_trigger_fingerprint}'
