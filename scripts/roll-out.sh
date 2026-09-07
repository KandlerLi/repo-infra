#!/usr/bin/env bash
# Mimics what a real CI pipeline would do for this repo's own apply,
# run locally: pull the credentials this repo's Terraform needs, run
# it, and leave nothing behind. Everything this script exports only
# ever lives inside its own process tree (a child `terraform` call, not
# the caller's interactive shell), so there's nothing to explicitly
# unset afterward -- unlike infra/k3s-apps' own scripts/export-tf-vars.sh,
# which is deliberately *sourced* so its exports persist for manual
# follow-up commands, this script runs terraform itself.
#
#   scripts/roll-out.sh plan
#   scripts/roll-out.sh apply
#
# Needs:
# - AWS credentials for the repo-infra-local IAM identity, in pass at
#   aws/repo-infra-local/access-key-id and .../secret-access-key -- see
#   this repo's own README.md, "First apply" section in
#   bootstrap/terraform-state/README.md's "repo-infra-local Identity"
#   for how those got there in the first place.
# - `gh` already authenticated locally (GITHUB_TOKEN comes from
#   `gh auth token`, not a new credential).

set -euo pipefail

usage() {
  echo "usage: $(basename "$0") plan|apply" >&2
  exit 1
}

[ $# -eq 1 ] || usage
mode="$1"
case "$mode" in
  plan | apply) ;;
  *) usage ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname "${script_dir}")"

fail() {
  echo "roll-out.sh: $1" >&2
  exit 1
}

access_key_id="$(pass show aws/repo-infra-local/access-key-id 2>/dev/null | head -1 || true)"
[ -n "${access_key_id}" ] || fail "pass entry aws/repo-infra-local/access-key-id is empty or missing -- see bootstrap/terraform-state/README.md's 'repo-infra-local Identity' section"

secret_access_key="$(pass show aws/repo-infra-local/secret-access-key 2>/dev/null | head -1 || true)"
[ -n "${secret_access_key}" ] || fail "pass entry aws/repo-infra-local/secret-access-key is empty or missing -- see bootstrap/terraform-state/README.md's 'repo-infra-local Identity' section"

github_token="$(gh auth token 2>/dev/null || true)"
[ -n "${github_token}" ] || fail "gh auth token returned nothing -- run 'gh auth login' first"

export AWS_ACCESS_KEY_ID="${access_key_id}"
export AWS_SECRET_ACCESS_KEY="${secret_access_key}"
export GITHUB_TOKEN="${github_token}"

cd "${repo_root}"

terraform init -input=false
terraform fmt -check -recursive
terraform validate
terraform plan

if [ "${mode}" = "apply" ]; then
  # Interactive on purpose -- terraform's own plan-and-confirm prompt is
  # the review step, not -auto-approve.
  terraform apply
fi
