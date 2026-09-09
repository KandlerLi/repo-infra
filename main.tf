data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  config = yamldecode(file("./config.yml"))
}

module "repo" {
  source = "./modules/repo"

  for_each = local.config

  repository_name  = each.key
  action_variables = try(each.value.action_variables, {})
  # No live source for this any more -- action_secrets.tf (the
  # TF_VAR_*-sourced values behind it) was deleted 2026-09-09 once
  # k3s-apps, its only consumer, finished moving every one of those
  # secrets to AWS Secrets Manager (read directly at `terraform plan`
  # time via k3s-apps' own secrets.tf, not a GitHub Actions secret at
  # all any more -- see PARKED.md's SOPS-to-Secrets-Manager writeup).
  # config.yml's own action_secrets: lists are gone with it. Left as an
  # empty map, not removed outright -- modules/repo's own
  # action_secrets variable is a generic mechanism for a real secret
  # with no OIDC/Secrets-Manager equivalent, worth keeping for the next
  # repo that actually needs one; re-wire a fresh sensitive-variables
  # file the same shape as the old action_secrets.tf when that happens.
  action_secrets                 = {}
  required_status_check_contexts = try(each.value.required_status_check_contexts, [])
  visibility                     = try(each.value.visibility, "public")
  branch_protection_enabled      = try(each.value.branch_protection_enabled, true)

  aws = try(local.aws_policies[each.key], null) == null ? null : merge(
    local.aws_policies[each.key],
    {
      apply_policy_statements = jsonencode(local.aws_policies[each.key].apply_policy_statements)
      plan_policy_statements  = jsonencode(local.aws_policies[each.key].plan_policy_statements)
    }
  )

  oidc_provider_arn = aws_iam_openid_connect_provider.github.arn
  aws_account_id    = data.aws_caller_identity.current.account_id
}
