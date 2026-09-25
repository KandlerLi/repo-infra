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
# docs/home-infra-ai-context/context/decisions.md). After a fix, the
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

data "external" "pr_creation_policy" {
  for_each = local.config

  program = [
    "gh", "api", "repos/${local.github_owner}/${module.repo[each.key].name}",
    "--jq", "{policy: (.pull_request_creation_policy // \"unknown\")}",
  ]
}

resource "terraform_data" "pr_creation_policy" {
  for_each = local.config

  triggers_replace = data.external.pr_creation_policy[each.key].result.policy == "collaborators_only"

  provisioner "local-exec" {
    command = "gh api --method PATCH repos/${local.github_owner}/${each.key} -f pull_request_creation_policy=collaborators_only --silent"
  }
}

data "external" "fork_pr_approval" {
  for_each = local.public_repositories

  program = [
    "gh", "api", "repos/${local.github_owner}/${module.repo[each.key].name}/actions/permissions/fork-pr-contributor-approval",
    "--jq", "{policy: .approval_policy}",
  ]
}

resource "terraform_data" "fork_pr_approval" {
  for_each = local.public_repositories

  triggers_replace = data.external.fork_pr_approval[each.key].result.policy == "all_external_contributors"

  provisioner "local-exec" {
    command = "gh api --method PUT repos/${local.github_owner}/${each.key}/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors --silent"
  }
}
