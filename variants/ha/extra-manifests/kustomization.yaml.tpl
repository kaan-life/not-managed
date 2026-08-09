apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - kured-patch-marker.yaml
  # Vendored from k3s, so that k3s stops owning it. GENERATED — see
  # scripts/vendor-local-path.sh and the header inside the file.
  - local-path-provisioner.yaml
