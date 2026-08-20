locals {
  config = yamldecode(file("./config.yml"))
}

module "repo" {
  source = "./modules/repo"

  for_each = local.config

  repository_name  = each.key
  action_variables = try(each.value.action_variables, {})
}