# SPDX-License-Identifier: Apache-2.0

resource "kubernetes_manifest" "letsencrypt" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt"
    }
    spec = {
      acme = {
        # Production or staging — an input with no default, because either default is
        # wrong in a way you only discover later. See variable "acme_server".
        server = var.acme_server
        email  = var.letsencrypt_email
        privateKeySecretRef = {
          name = "letsencrypt-account-key"
        }
        solvers = [
          {
            http01 = {
              ingress = {
                ingressClassName = "traefik"
              }
            }
          }
        ]
      }
    }
  }

  depends_on = [module.kube-hetzner]
}
