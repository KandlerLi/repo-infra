# Two repository settings terraform-provider-github has no resource for
# (upstream issue #3198): who may open a pull request, and which fork
# PRs need the owner's approval before their workflows run. Both keep
# strangers' code off the self-hosted runners, which every public repo
# here uses.
#
# Pattern: a data source reads the live value on every plan, and a
# terraform_data keyed on "is it correct?" runs the gh api fix only
# when it isn't -- so plan shows drift and apply corrects it. A bare
# local-exec without that read is not acceptable here (see
# KandlerLi/home-infra-docs/docs/decisions.md). After a fix, the
# next plan shows one more harmless replacement as the trigger flips
# back to true; the command is idempotent.
#
# Needs a gh CLI logged in with admin rights on these repos -- this
# root is local-only, never CI.

locals {
  github_owner = "KandlerLi"

  # GitHub rejects the fork-approval endpoint for private repositories;
  # only collaborators can fork those anyway.
  public_repositories = {
    for name, cfg in local.config : name => cfg
    if try(cfg.visibility, "public") == "public"
  }
}

# A repo created in this same apply doesn't exist yet when this reads
# (404); report it as not yet correct so the fix below runs after the
# repo is created. Any other error still fails the plan.
data "external" "pr_creation_policy" {
  for_each = local.config

  program = [
    "sh", "-c", <<-EOT
      repo="repos/${local.github_owner}/${module.repo[each.key].name}"
      if gh api "$repo" --silent 2>&1 | grep -q "HTTP 404"; then
        echo '{"policy": "repository missing"}'
      else
        gh api "$repo" --jq '{policy: (.pull_request_creation_policy // "unknown")}'
      fi
    EOT
  ]
}

resource "terraform_data" "pr_creation_policy" {
  for_each = local.config

  triggers_replace = data.external.pr_creation_policy[each.key].result.policy == "collaborators_only"

  provisioner "local-exec" {
    command = "gh api --method PATCH repos/${local.github_owner}/${each.key} -f pull_request_creation_policy=collaborators_only --silent"
  }
}

# A repo switching to public in this same apply is still private when
# this reads, and GitHub rejects the call; report it as not yet correct
# instead. The fix below runs after the visibility change (it depends on
# module.repo via the name), so one apply covers both.
data "external" "fork_pr_approval" {
  for_each = local.public_repositories

  program = [
    "sh", "-c", <<-EOT
      repo="repos/${local.github_owner}/${module.repo[each.key].name}"
      if [ "$(gh api "$repo" --jq .private)" = "true" ]; then
        echo '{"policy": "repository still private"}'
      else
        gh api "$repo/actions/permissions/fork-pr-contributor-approval" --jq '{policy: .approval_policy}'
      fi
    EOT
  ]
}

resource "terraform_data" "fork_pr_approval" {
  for_each = local.public_repositories

  triggers_replace = data.external.fork_pr_approval[each.key].result.policy == "all_external_contributors"

  provisioner "local-exec" {
    command = "gh api --method PUT repos/${local.github_owner}/${each.key}/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors --silent"
  }
}
