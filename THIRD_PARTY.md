# Third-party components

Everything this repository depends on, with its license, its pinned version, and — the
column that actually decides whether there is an obligation — whether it is **distributed**
here or merely **referenced**.

Copying a file creates an attribution obligation. Pinning a version number does not: a
version string is not a distribution of code. That distinction is the whole structure of
this document, and it is recorded as a decision in `docs/adr/0005-attribution-matrix.md`.

Everything in the "distributed" table also appears in `NOTICE`, which is the file that has
to travel with a redistribution. This one is the inventory.

## Distributed — attribution required

| Component | Pinned | License | What is distributed here |
|---|---|---|---|
| [kube-hetzner/terraform-hcloud-kube-hetzner](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner) | v2.19.2 | MIT | `variants/*/packer/hcloud-microos-snapshots.pkr.hcl` — differs from upstream in 18 lines of ~210 (SHA256 verification of the MicroOS images), so it carries an MIT SPDX identifier rather than the project's Apache-2.0 one. And `variants/*/main.tf`, which shares 30 of 249 substantive unique lines with upstream's `kube.tf.example` — configuration-level derivation, attributed out of caution. |
| [k3s-io/k3s](https://github.com/k3s-io/k3s) | v1.33.13+k3s2 | Apache-2.0 | `variants/*/extra-manifests/local-path-provisioner.yaml.tpl`, generated from `manifests/local-storage.yaml` by `scripts/vendor-local-path.sh`. |
| [rancher/local-path-provisioner](https://github.com/rancher/local-path-provisioner) | as packaged by k3s above | Apache-2.0 | The workload that the vendored manifest deploys. |

Upstream `kube-hetzner`'s `LICENSE` carries the MIT permission text with **no copyright
holder line**. `NOTICE` reproduces the permission text verbatim and attributes by project
name, URL and pinned version instead of inventing a holder. Neither `k3s` nor
`local-path-provisioner` publishes a `NOTICE` file, so there are no further attribution
notices to propagate.

## Referenced only — no obligation, listed for completeness

### Terraform providers

Read from `variants/*/.terraform.lock.hcl`, which is the authoritative list: five are
declared in `providers.tf` and the other seven are pulled in by the kube-hetzner module.
Each license was read from the provider's own repository.

| Provider | Version | License |
|---|---|---|
| [`hetznercloud/hcloud`](https://github.com/hetznercloud/terraform-provider-hcloud) | 1.60.1 | MPL-2.0 |
| [`integrations/github`](https://github.com/integrations/terraform-provider-github) | 6.12.1 | MIT |
| [`hashicorp/helm`](https://github.com/hashicorp/terraform-provider-helm) | 3.1.1 | MPL-2.0 |
| [`hashicorp/kubernetes`](https://github.com/hashicorp/terraform-provider-kubernetes) | 3.0.1 | MPL-2.0 |
| [`hashicorp/time`](https://github.com/hashicorp/terraform-provider-time) | 0.13.1 | MPL-2.0 |
| [`hashicorp/assert`](https://github.com/hashicorp/terraform-provider-assert) | 0.16.0 | MPL-2.0 |
| [`hashicorp/cloudinit`](https://github.com/hashicorp/terraform-provider-cloudinit) | 2.3.7 | MPL-2.0 |
| [`hashicorp/local`](https://github.com/hashicorp/terraform-provider-local) | 2.7.0 | MPL-2.0 |
| [`hashicorp/random`](https://github.com/hashicorp/terraform-provider-random) | 3.8.1 | MPL-2.0 |
| [`anapsix/semvers`](https://github.com/anapsix/terraform-provider-semvers) | 0.7.1 | MPL-2.0 |
| [`isometry/deepmerge`](https://github.com/isometry/terraform-provider-deepmerge) | 1.2.1 | MPL-2.0 |
| [`loafoe/ssh`](https://github.com/loafoe/terraform-provider-ssh) | 2.7.0 | MIT — © 2021 Andy Lo-A-Foe |

**The 2023 HashiCorp relicensing did not reach these.** It applied to the *products*
(see the CLI note below), not to the official Terraform providers, every one of which is
still MPL-2.0. That was checked rather than assumed, because assuming the opposite is the
easier mistake and it would have put a BUSL claim in a published document.

### Charts and container images

Fetched at deploy time from their own distributors; no copy of any of them is in this
repository.

| Component | Pinned | License |
|---|---|---|
| [Argo CD Helm chart](https://github.com/argoproj/argo-helm) | chart 8.2.5 | Apache-2.0 |
| [Argo CD](https://github.com/argoproj/argo-cd) | via the chart | Apache-2.0 |
| [hcloud-csi-driver](https://github.com/hetznercloud/csi-driver) | v2.22.0 | MIT |
| [hcloud-cloud-controller-manager](https://github.com/hetznercloud/hcloud-cloud-controller-manager) | v1.22.0 | Apache-2.0 |
| [kured](https://github.com/kubereboot/kured) | 1.21.0 | Apache-2.0 |
| [cert-manager](https://github.com/cert-manager/cert-manager) | v1.20.3 | Apache-2.0 |
| [Traefik Helm chart](https://github.com/traefik/traefik-helm-chart) | 41.0.0 | Apache-2.0 |
| [k3s](https://github.com/k3s-io/k3s) | channel `v1.33` | Apache-2.0 |
| [openSUSE MicroOS](https://get.opensuse.org/microos/) | rolling | mixed; see openSUSE |

### Command-line tools

Not dependencies of the configuration — tools you run against it. Listed because their
licensing is the one thing in this inventory that surprises people.

| Tool | License | Note |
|---|---|---|
| Terraform CLI | **BUSL-1.1** from v1.6 onward | Relicensed in 2023. It restricts offering a competing product; **it does not restrict publishing or using HCL configuration**, which is all this repository is. See `docs/adr/0004-terraform-only-opentofu-untested.md`. |
| Packer CLI | **BUSL-1.1** | Same relicensing. Used only to build the MicroOS snapshots. |
| OpenTofu | MPL-2.0 | A drop-in alternative to the Terraform CLI. **Untested here** — ADR-0004 chose to say so rather than claim compatibility nobody verified. |

## Keeping this accurate

Every version in this file is pinned somewhere in the repository, so this document goes
stale the moment a pin moves. Two things keep it honest:

- Dependabot watches the `terraform` ecosystem, so a pin change arrives as a pull request
  rather than as a surprise.
- Changing a pin means changing this file in the same pull request. It is part of the
  upgrade checklist, not an afterthought — that consequence is recorded in ADR-0005.
