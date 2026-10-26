#!/usr/bin/env bash
# Local plan/apply with the repo-infra-local identity: see README, "Rolling out locally".

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
[ -n "${access_key_id}" ] || fail "pass entry aws/repo-infra-local/access-key-id is empty or missing -- see KandlerLi/terraform-state/README.md's 'repo-infra-local Identity' section"

secret_access_key="$(pass show aws/repo-infra-local/secret-access-key 2>/dev/null | head -1 || true)"
[ -n "${secret_access_key}" ] || fail "pass entry aws/repo-infra-local/secret-access-key is empty or missing -- see KandlerLi/terraform-state/README.md's 'repo-infra-local Identity' section"

github_token="$(gh auth token 2>/dev/null || true)"
[ -n "${github_token}" ] || fail "gh auth token returned nothing -- run 'gh auth login' first"

export AWS_ACCESS_KEY_ID="${access_key_id}"
export AWS_SECRET_ACCESS_KEY="${secret_access_key}"
export GITHUB_TOKEN="${github_token}"

cd "${repo_root}"

terraform init -input=false
terraform fmt -check -recursive
terraform validate
# -input=false: fail on a missing variable instead of prompting for it.
if [ "${mode}" = "plan" ]; then
  terraform plan -input=false
else
  # Interactive on purpose: apply prints the plan itself and its confirm prompt is the review step.
  terraform apply -input=false
fi
