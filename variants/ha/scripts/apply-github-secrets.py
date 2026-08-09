#!/usr/bin/env python3
"""Apply GitHub App credentials as Kubernetes secrets, keeping PEM content out of Terraform state."""
import json
import os
import re
import subprocess
import sys


def validate_namespace(name: str) -> bool:
    return bool(re.match(r"^[a-z0-9]([a-z0-9\-]*[a-z0-9])?$", name)) and len(name) <= 63


# kubectl blocks indefinitely when the API server is reachable but not answering — a
# control plane mid-restart, a NotReady node, a tailnet hiccup. Without a timeout this
# script hangs, so the local-exec provisioner hangs, so `terraform apply` hangs while
# holding the S3 state lock. A hung apply is worse than a failed one: the failure is
# visible and the lock is released.
KUBECTL_TIMEOUT_SECONDS = 120


def kubectl_apply(manifest: dict) -> None:
    try:
        result = subprocess.run(
            ["kubectl", "apply", "-f", "-"],
            input=json.dumps(manifest).encode(),
            capture_output=True,
            timeout=KUBECTL_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        print(
            f"kubectl apply did not return within {KUBECTL_TIMEOUT_SECONDS}s. "
            "The API server is probably reachable but not answering — check "
            "`kubectl get nodes` and the control plane before retrying.",
            file=sys.stderr,
        )
        sys.exit(1)
    if result.returncode != 0:
        print(result.stderr.decode(), file=sys.stderr)
        sys.exit(1)


def main() -> None:
    pem_path = os.environ.get("GITHUB_APP_PEM_PATH", "")
    app_id = os.environ.get("GITHUB_APP_ID", "")
    installation_id = os.environ.get("GITHUB_APP_INSTALLATION_ID", "")
    github_org_url = os.environ.get("GITHUB_ORG_URL", "")
    namespaces_raw = os.environ.get("APP_NAMESPACES", "")

    errors = []
    if not pem_path:
        errors.append("GITHUB_APP_PEM_PATH is required")
    elif not os.path.isfile(pem_path):
        errors.append(f"PEM file not found: {pem_path}")

    if not re.match(r"^\d+$", app_id):
        errors.append(f"GITHUB_APP_ID must be numeric, got: {app_id!r}")
    if not re.match(r"^\d+$", installation_id):
        errors.append(f"GITHUB_APP_INSTALLATION_ID must be numeric, got: {installation_id!r}")
    if not re.match(r"^https://github\.com/[A-Za-z0-9_.-]+/?$", github_org_url):
        errors.append(f"GITHUB_ORG_URL is invalid: {github_org_url!r}")

    namespaces = [ns.strip() for ns in namespaces_raw.split(",") if ns.strip()]
    for ns in namespaces:
        if not validate_namespace(ns):
            errors.append(f"invalid namespace name: {ns!r}")

    if errors:
        for err in errors:
            print(f"ERROR: {err}", file=sys.stderr)
        sys.exit(1)

    with open(pem_path) as f:
        pem_content = f.read()

    if not pem_content.startswith("-----BEGIN"):
        print("ERROR: PEM file does not appear to be a valid PEM file", file=sys.stderr)
        sys.exit(1)

    kubectl_apply({
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {
            "name": "argocd-github-app",
            "namespace": "argocd",
            "labels": {"argocd.argoproj.io/secret-type": "repo-creds"},
        },
        "type": "Opaque",
        "stringData": {
            "type": "git",
            "url": github_org_url.rstrip("/"),
            "githubAppID": app_id,
            "githubAppInstallationID": installation_id,
            "githubAppPrivateKey": pem_content,
        },
    })
    print("Applied argocd-github-app in namespace argocd")

    for ns in namespaces:
        kubectl_apply({
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {"name": "github-app-credentials", "namespace": ns},
            "type": "Opaque",
            "stringData": {
                "app_id": app_id,
                "installation_id": installation_id,
                "private_key": pem_content,
            },
        })
        print(f"Applied github-app-credentials in namespace {ns}")


if __name__ == "__main__":
    main()
