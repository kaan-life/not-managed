# SPDX-License-Identifier: Apache-2.0

provider "hcloud" {
  token = var.hcloud_token
}

provider "kubernetes" {
  host                   = module.kube-hetzner.kubeconfig_data.host
  client_certificate     = module.kube-hetzner.kubeconfig_data.client_certificate
  client_key             = module.kube-hetzner.kubeconfig_data.client_key
  cluster_ca_certificate = module.kube-hetzner.kubeconfig_data.cluster_ca_certificate
}

provider "helm" {
  kubernetes = {
    host                   = module.kube-hetzner.kubeconfig_data.host
    client_certificate     = module.kube-hetzner.kubeconfig_data.client_certificate
    client_key             = module.kube-hetzner.kubeconfig_data.client_key
    cluster_ca_certificate = module.kube-hetzner.kubeconfig_data.cluster_ca_certificate
  }
}

# Authenticates as the ArgoCD GitHub App using the PEM already on disk, so no
# additional long-lived credential is needed. The App must have the
# `repository_hooks: write` permission (plus the existing contents/metadata read) and
# that permission must be approved on the org installation, otherwise every
# github_repository_webhook operation fails with HTTP 403 "Resource not accessible by
# integration".
provider "github" {
  owner = trimsuffix(trimprefix(var.github_org_url, "https://github.com/"), "/")

  app_auth {
    id              = var.github_app_id
    installation_id = var.github_app_installation_id
    pem_file        = file("${path.module}/${var.github_app_private_key_path}")
  }
}

terraform {
  required_version = "~> 1.10"

  # Remote state backend for an S3-compatible object store, declared as a PARTIAL
  # backend: nothing here says WHICH state store to use.
  #
  # It used to. `bucket = "<a real bucket name>"` was a literal in this file, because a
  # backend block cannot reference var.* — Terraform has no syntax for it, and the
  # comment that used to sit here said so and stopped there. The consequence is why this
  # changed: anyone who cloned the repository and ran `terraform init` with their own
  # cloud credentials initialised against the ORIGINAL author's production state. Not a
  # copy of it — the same object. The first `apply` after that plans a green-field
  # cluster as a diff against somebody else's running one, and the second one adopts or
  # destroys it. Nothing warns you; from Terraform's point of view you asked for this.
  #
  # bucket / key / region / endpoints now come from a file that is never committed:
  #
  #     cp backend.hcl.example backend.hcl   # then fill it in
  #     terraform init -backend-config=backend.hcl
  #
  # Measured behaviour when that flag is missing: `terraform init -input=false` exits 1
  # with `Missing Required Value: The attribute "bucket" is required by the backend`
  # (and the same for "key"); an interactive `terraform init` prompts for the bucket
  # instead of assuming one. Note that `region` alone can also be satisfied by AWS_REGION
  # in the environment — `bucket` and `key` cannot, and those are the two that decide
  # whose state you are about to write. CI never needs the file at all:
  # `terraform init -backend=false` skips the backend entirely and needs no credentials.
  #
  # What is left below is protocol behaviour, not identity. It describes how to speak to
  # an S3-compatible endpoint that is not AWS, and it is identical for every user of this
  # configuration; moving it into backend.hcl would add four more ways to misconfigure a
  # working setup without removing any exposure. Credentials are not here either: the
  # backend reads AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY from the environment, which
  # init.sh and destroy.sh export before calling `terraform init`.
  backend "s3" {
    use_path_style              = true # required for S3-compatible APIs
    use_lockfile                = true # native .tflock locking — no DynamoDB (Terraform 1.10+)
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true # non-AWS stores have no STS endpoint
  }

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.12"
    }
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.60"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}
