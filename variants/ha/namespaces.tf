# SPDX-License-Identifier: Apache-2.0

locals {
  all_namespaces = concat(var.app_namespaces, var.utility_namespaces)
}

resource "kubernetes_namespace_v1" "app_namespaces" {
  for_each = toset(local.all_namespaces)

  metadata {
    name = each.key
  }
}
