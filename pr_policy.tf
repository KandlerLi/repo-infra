# Settings the provider can't manage (issue #3198): read live, fix via gh api only on drift. See README.

locals {
  github_owner = "KandlerLi"

  # GitHub rejects the fork-approval endpoint for private repos.
  public_repositories = {
    for name, cfg in local.config : name => cfg
    if try(cfg.visibility, "public") == "public"
  }
}

# A repo created in this apply 404s here: report it not yet correct so the fix runs after creation.
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

# A repo created or going public in this apply 404s or reads private: report it not yet correct, the fix runs after.
data "external" "fork_pr_approval" {
  for_each = local.public_repositories

  program = [
    "sh", "-c", <<-EOT
      repo="repos/${local.github_owner}/${module.repo[each.key].name}"
      if gh api "$repo" --silent 2>&1 | grep -q "HTTP 404"; then
        echo '{"policy": "repository missing"}'
      elif [ "$(gh api "$repo" --jq .private)" = "true" ]; then
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
