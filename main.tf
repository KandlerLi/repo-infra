locals {
  config = yamldecode(file("./config.yml"))
}

module "repo" {
  source = "./modules/repo"

  for_each = local.config

  repository_name      = each.key
  action_variables     = try(each.value.action_variables, {})
  sha_pinning_required = try(each.value.sha_pinning_required, false)
}