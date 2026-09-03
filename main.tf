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
  action_secrets = {
    for name in try(each.value.action_secrets, []) : name => local.action_secret_values[name]
  }
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
