locals {
  config = yamldecode(file("./config.yml"))
}

module "repo" {
  source = "./modules/repo"

  for_each = local.config

  repository_name = each.key
  github_owner    = "dummy"
  action_variables = try(each.value.action_variables, {})
}

import {
  to = module.repo["dyndns"].github_actions_repository_permissions.this
  id = "dyndns"
}