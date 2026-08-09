#!/usr/bin/env python3
"""Apply the ArgoCD root ApplicationSet.

Called by terraform_data.argocd_root_appset local-exec provisioner.
Reads NAMESPACES (comma-separated), GITHUB_ORG, and GITHUB_REPO_NAME from the environment.
Constructs repoURL as GITHUB_ORG/GITHUB_REPO_NAME.
"""
import json
import os
import re
import subprocess
import sys


def valid_k8s_name(name: str) -> bool:
    return bool(re.match(r"^[a-z0-9]([a-z0-9\-]*[a-z0-9])?$", name))


namespaces_raw = os.environ.get("NAMESPACES", "")
github_org = os.environ.get("GITHUB_ORG", "")
github_repo_name = os.environ.get("GITHUB_REPO_NAME", "")

if not namespaces_raw:
    print("Error: NAMESPACES env var is empty", file=sys.stderr)
    sys.exit(1)

if not re.match(r"^https://github\.com/[A-Za-z0-9_.-]+/?$", github_org):
    print(f"Error: GITHUB_ORG is not a valid GitHub org URL: {github_org!r}", file=sys.stderr)
    sys.exit(1)

if not re.match(r"^[A-Za-z0-9_.-]+$", github_repo_name):
    print(f"Error: GITHUB_REPO_NAME is not a valid repo name: {github_repo_name!r}", file=sys.stderr)
    sys.exit(1)

repo_url = github_org.rstrip("/") + "/" + github_repo_name

namespaces = [ns.strip() for ns in namespaces_raw.split(",") if ns.strip()]

for ns in namespaces:
    if not valid_k8s_name(ns):
        print(f"Error: invalid namespace name {ns!r} (must match [a-z0-9][a-z0-9-]*[a-z0-9])", file=sys.stderr)
        sys.exit(1)

manifest = {
    "apiVersion": "argoproj.io/v1alpha1",
    "kind": "ApplicationSet",
    "metadata": {"name": "root", "namespace": "argocd"},
    "spec": {
        "generators": [{"list": {"elements": [{"environment": ns} for ns in namespaces]}}],
        "template": {
            "metadata": {
                "name": "{{environment}}",
                "namespace": "argocd",
                "finalizers": ["resources-finalizer.argocd.argoproj.io"],
            },
            "spec": {
                "project": "default",
                "source": {
                    "repoURL": repo_url,
                    "targetRevision": "main",
                    "path": "{{environment}}",
                },
                "destination": {
                    "server": "https://kubernetes.default.svc",
                    "namespace": "{{environment}}",
                },
                # prune=false: orphaned resources require an explicit manual sync --prune.
                # Prevents a bad git push from auto-deleting workloads across all namespaces.
                # RespectIgnoreDifferences: without it every auto-sync strips the
                # runtime-injected CRD conversion config (Tekton webhook re-adds it),
                # producing a permanent OutOfSync/resync loop (audit 2026-06-12).
                "syncPolicy": {
                    "automated": {"prune": False, "selfHeal": True},
                    "syncOptions": ["RespectIgnoreDifferences=true"],
                },
                # Mirrors the GitOps repo's Tekton CRD Application: /spec/conversion is fully
                # runtime-managed (caBundle, service path/port); listKind and
                # preserveUnknownFields are apiserver-defaulting noise.
                "ignoreDifferences": [
                    {
                        "group": "apiextensions.k8s.io",
                        "kind": "CustomResourceDefinition",
                        "jsonPointers": [
                            "/spec/conversion",
                            "/spec/names/listKind",
                            "/spec/preserveUnknownFields",
                        ],
                    }
                ],
            },
        },
    },
}

# See the note in apply-github-secrets.py: kubectl blocks indefinitely when the API
# server is reachable but not answering, which hangs this script, the local-exec
# provisioner, and `terraform apply` — holding the S3 state lock the whole time.
KUBECTL_TIMEOUT_SECONDS = 120

try:
    proc = subprocess.run(
        ["kubectl", "apply", "-f", "-"],
        input=json.dumps(manifest),
        text=True,
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

print(proc.stdout)
if proc.returncode != 0:
    print(proc.stderr, file=sys.stderr)
    sys.exit(proc.returncode)
