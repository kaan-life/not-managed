output "kubeconfig" {
  value     = module.kube-hetzner.kubeconfig
  sensitive = true
}

output "argocd_admin_password" {
  value     = try(data.kubernetes_secret_v1.argocd_admin_password.data["password"], "secret-already-deleted")
  sensitive = true
}