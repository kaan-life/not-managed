# SPDX-License-Identifier: Apache-2.0

resource "terraform_data" "github_secrets" {
  triggers_replace = {
    pem_hash        = filesha256("${path.module}/${var.github_app_private_key_path}")
    app_id          = var.github_app_id
    installation_id = var.github_app_installation_id
    namespaces      = join(",", var.app_namespaces)

    # Same reasoning as the PEM hash above, applied to the script that reads it: an
    # edit to apply-github-secrets.py was previously invisible to Terraform and so
    # was never rolled out.
    #
    # SIDE EFFECT WORTH KNOWING BEFORE YOU EDIT THAT FILE: this hash makes every byte of
    # it load-bearing, including comments. That is why the two Python helpers are the only
    # source files in this repository without an SPDX header — adding one would replace
    # this terraform_data and re-run the script against a live cluster for a licence
    # comment. They are Apache-2.0 like everything else that carries no header; LICENSE
    # says so. Add the headers with the next change that is going to apply anyway.
    script_hash = filesha256("${path.module}/scripts/apply-github-secrets.py")
  }

  provisioner "local-exec" {
    environment = {
      KUBECONFIG                 = "${abspath(path.root)}/k3s_kubeconfig.yaml"
      GITHUB_APP_PEM_PATH        = "${abspath(path.root)}/${var.github_app_private_key_path}"
      GITHUB_APP_ID              = var.github_app_id
      GITHUB_APP_INSTALLATION_ID = var.github_app_installation_id
      GITHUB_ORG_URL             = var.github_org_url
      APP_NAMESPACES             = join(",", var.app_namespaces)
    }
    command = "python3 ${abspath(path.root)}/scripts/apply-github-secrets.py"
  }

  depends_on = [
    helm_release.argocd,
    kubernetes_namespace_v1.app_namespaces,
  ]
}
