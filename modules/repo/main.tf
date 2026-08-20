resource "github_repository" "this" {
  name = var.repository_name

  visibility = "public"

  has_projects           = true
  delete_branch_on_merge = true
  has_issues             = true

  allow_merge_commit  = false
  allow_rebase_merge  = false
  allow_update_branch = true
}

resource "github_repository_ruleset" "default_branch" {
  name        = "Main"
  repository  = github_repository.this.name
  target      = "branch"
  enforcement = "disabled"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion                = true
    non_fast_forward        = true
    required_linear_history = false
  }
}

resource "github_actions_variable" "aws_account_id" {
  repository    = github_repository.this.name
  variable_name = "AWS_ACCOUNT_ID"
  value         = "853955636908"
}

resource "github_actions_variable" "aws_plan_role_arn" {
  repository    = github_repository.this.name
  variable_name = "AWS_PLAN_ROLE_ARN"
  value         = "arn:aws:iam::853955636908:role/${github_repository.this.name}-github-plan"
}

resource "github_actions_variable" "aws_role_arn" {
  repository    = github_repository.this.name
  variable_name = "AWS_ROLE_ARN"
  value         = "arn:aws:iam::853955636908:role/${github_repository.this.name}-github-actions"
}

resource "github_actions_variable" "additional" {
  for_each = var.action_variables

  repository    = github_repository.this.name
  variable_name = each.key
  value         = each.value
}


resource "github_repository_environment" "production" {
  environment = "production"
  repository  = github_repository.this.name
  reviewers {
    users = [24520951]
  }
  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }
}

resource "github_actions_repository_permissions" "this" {
  allowed_actions      = "selected"
  sha_pinning_required = true
  allowed_actions_config {
    github_owned_allowed = false
    patterns_allowed = [
      "actions/checkout@*",
      "aws-actions/configure-aws-credentials@*",
      "hashicorp/setup-terraform@*"
    ]
    verified_allowed = false
  }
  repository = github_repository.this.name
}

resource "github_workflow_repository_permissions" "this" {
  repository                       = github_repository.this.name
  default_workflow_permissions     = "read"
  can_approve_pull_request_reviews = false
}
