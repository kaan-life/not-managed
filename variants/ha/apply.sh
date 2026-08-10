#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Day-2 apply: skip Packer build and phased apply, run one full terraform apply.
# Equivalent to: bash init.sh --apply-only
set -euo pipefail

exec bash "$(dirname "$0")/init.sh" --apply-only "$@"
