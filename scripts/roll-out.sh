#!/usr/bin/env bash
# Mimics what a real CI pipeline would do for this repo's own apply,
# run locally: pull the credentials this repo's Terraform needs, run
# it, and leave nothing behind. Everything this script exports --
# including infra/k3s-apps' own scripts/export-tf-vars.sh, sourced
# below -- only ever lives inside this script's own process tree (a
# child `terraform` call, not the caller's interactive shell), so
# there's nothing to explicitly unset afterward even though
# export-tf-vars.sh is itself designed to be sourced for its exports
# to persist (matching bootstrap/k3s-bootstrap's own roll-out.sh,
# which sources it the exact same way for the exact same reason).
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
# - home-infra's and this repo's own secrets.sops.yml, decrypted by
#   export-tf-vars.sh below -- see that script's own
#   print_tf_var_exports.py for exactly which keys it reads.

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
k3s_apps_dir="${K3S_APPS_DIR:-$(cd "${repo_root}/../../infra/k3s-apps" 2>/dev/null && pwd || true)}"

fail() {
  echo "roll-out.sh: $1" >&2
  exit 1
}

[ -n "${k3s_apps_dir}" ] && [ -f "${k3s_apps_dir}/scripts/export-tf-vars.sh" ] \
  || fail "can't find infra/k3s-apps' scripts/export-tf-vars.sh (looked in '${k3s_apps_dir:-<unset>}') -- set K3S_APPS_DIR if your checkout layout differs"

access_key_id="$(pass show aws/repo-infra-local/access-key-id 2>/dev/null | head -1 || true)"
[ -n "${access_key_id}" ] || fail "pass entry aws/repo-infra-local/access-key-id is empty or missing -- see bootstrap/terraform-state/README.md's 'repo-infra-local Identity' section"

secret_access_key="$(pass show aws/repo-infra-local/secret-access-key 2>/dev/null | head -1 || true)"
[ -n "${secret_access_key}" ] || fail "pass entry aws/repo-infra-local/secret-access-key is empty or missing -- see bootstrap/terraform-state/README.md's 'repo-infra-local Identity' section"

github_token="$(gh auth token 2>/dev/null || true)"
[ -n "${github_token}" ] || fail "gh auth token returned nothing -- run 'gh auth login' first"

export AWS_ACCESS_KEY_ID="${access_key_id}"
export AWS_SECRET_ACCESS_KEY="${secret_access_key}"
export GITHUB_TOKEN="${github_token}"

# Sourced *inside this script's own process*, not the caller's
# interactive shell (this script is executed, not sourced) -- so
# nothing it exports outlives this run either, same as the AWS/
# GITHUB_TOKEN exports above. Now correctly fails this whole script
# (k3s-apps' own export-tf-vars.sh returns non-zero when a secret is
# missing, see that script's own history) rather than silently
# continuing into terraform with nothing set.
# shellcheck source=/dev/null
source "${k3s_apps_dir}/scripts/export-tf-vars.sh"

cd "${repo_root}"

terraform init -input=false
terraform fmt -check -recursive
terraform validate
# -input=false on plan/apply too, not just init -- confirmed live,
# 2026-09-08: a missing/unexported required variable otherwise drops
# into an interactive "var.foo" prompt instead of failing outright,
# which is easy to misread as a wall of unrelated broken variables
# (Terraform prompts for every one it can't resolve, one at a time)
# rather than the one real cause (nothing got exported at all, often
# because a single secret is missing further up an all-or-nothing
# export script). This makes that fail fast with a clear "No value for
# required variable" error instead.
terraform plan -input=false

if [ "${mode}" = "apply" ]; then
  # Interactive on purpose -- terraform's own plan-and-confirm prompt is
  # the review step, not -auto-approve. -input=false doesn't affect
  # that prompt, only variable-value prompts.
  terraform apply -input=false
fi
