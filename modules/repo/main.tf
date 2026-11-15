resource "github_repository" "this" {
  name = var.repository_name

  visibility = var.visibility
  archived   = var.archived

  has_projects           = true
  delete_branch_on_merge = true
  has_issues             = true
  has_wiki               = false

  allow_merge_commit  = false
  allow_rebase_merge  = false
  allow_update_branch = true
  allow_auto_merge    = false
}

# Skipped for archived repos: provider <= v6.13.0 fails the whole plan reading it there.
resource "github_repository_vulnerability_alerts" "this" {
  count = var.archived ? 0 : 1

  repository = github_repository.this.name
  enabled    = true
}

moved {
  from = github_repository_vulnerability_alerts.this
  to   = github_repository_vulnerability_alerts.this[0]
}

# A brand-new empty repo may need a second apply once main exists: see README.
resource "github_branch_default" "this" {
  repository = github_repository.this.name
  branch     = "main"
}

resource "github_branch_protection" "this" {
  count = var.branch_protection_enabled ? 1 : 0

  repository_id = github_repository.this.node_id
  pattern       = "main"

  enforce_admins                  = true
  require_conversation_resolution = true
  require_signed_commits          = true
  required_linear_history         = true
  allows_force_pushes             = false
  allows_deletions                = false

  required_pull_request_reviews {
    required_approving_review_count = 0
    require_code_owner_reviews      = false
    require_last_push_approval      = false
    dismiss_stale_reviews           = false
  }

  required_status_checks {
    strict   = true
    contexts = var.required_status_check_contexts
  }
}

resource "github_actions_variable" "aws_account_id" {
  count         = local.aws_enabled ? 1 : 0
  repository    = github_repository.this.name
  variable_name = "AWS_ACCOUNT_ID"
  value         = var.aws_account_id
}

resource "github_actions_variable" "aws_role_arn" {
  count         = local.aws_enabled ? 1 : 0
  repository    = github_repository.this.name
  variable_name = "AWS_ROLE_ARN"
  value         = aws_iam_role.apply[0].arn
}

resource "github_actions_variable" "aws_plan_role_arn" {
  count         = local.aws_enabled ? 1 : 0
  repository    = github_repository.this.name
  variable_name = "AWS_PLAN_ROLE_ARN"
  value         = aws_iam_role.plan[0].arn
}

resource "github_actions_variable" "additional" {
  for_each = var.action_variables

  repository    = github_repository.this.name
  variable_name = each.key
  value         = each.value
}

resource "github_actions_secret" "additional" {
  for_each = var.action_secrets

  repository  = github_repository.this.name
  secret_name = each.key
  value       = each.value
}


resource "github_repository_environment" "production" {
  # Kept without reviewers: the AWS OIDC trust requires environment:production. See README.
  count = var.branch_protection_enabled ? 1 : 0

  environment = "production"
  repository  = github_repository.this.name
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
    patterns_allowed = concat([
      "actions/checkout@*",
      "aws-actions/configure-aws-credentials@*",
      "hashicorp/setup-terraform@*",
      # gha-common's reusable workflows; this allowlist governs reusable workflows too.
      "KandlerLi/gha-common/.github/workflows/terraform-checks.yml@*",
      "KandlerLi/gha-common/.github/workflows/terraform-apply.yml@*",
      "KandlerLi/gha-common/.github/workflows/trivy-config.yml@*",
      # Matched by exact path, so each gha-common workflow needs its own entry.
      "KandlerLi/gha-common/.github/workflows/trivy-image.yml@*",
      "KandlerLi/gha-common/.github/workflows/gitleaks.yml@*",
      # Transitively called actions count too, not just the reusable workflow.
      "aquasecurity/trivy-action@*",
      # trivy-action's own nested actions.
      "aquasecurity/setup-trivy@*",
      "actions/cache@*",
      # Each actions/cache entry point is matched separately.
      "actions/cache/restore@*",
      "actions/cache/save@*",
      # For the plan PR comment in gha-common's terraform-checks.yml and k3s-apps.
      "actions/github-script@*"
    ], var.extra_allowed_actions)
    verified_allowed = false
  }
  repository = github_repository.this.name
}

resource "github_workflow_repository_permissions" "this" {
  repository                       = github_repository.this.name
  default_workflow_permissions     = "read"
  can_approve_pull_request_reviews = false
}

locals {
  aws_enabled = var.aws != null

  github_oidc_subject_base  = "repo:${var.github_owner}@${var.github_owner_id}/${github_repository.this.name}@${github_repository.this.repo_id}"
  github_apply_oidc_subject = "${local.github_oidc_subject_base}:environment:production"
  github_plan_oidc_subject  = "${local.github_oidc_subject_base}:pull_request"

  aws_state_bucket_arn = "arn:aws:s3:::jkandler-terraform-state"
  aws_state_lock_key   = local.aws_enabled ? "${var.aws.state_key}.tflock" : null
}

resource "aws_iam_role" "apply" {
  count = local.aws_enabled ? 1 : 0

  name        = "${var.repository_name}-github-actions"
  description = "Deploys ${var.repository_name} from its production environment"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.github_apply_oidc_subject
        }
      }
    }]
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role" "plan" {
  count = local.aws_enabled ? 1 : 0

  name        = "${var.repository_name}-github-plan"
  description = "Creates read-only Terraform plans for trusted ${var.repository_name} pull requests"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.github_plan_oidc_subject
        }
      }
    }]
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role_policy" "apply" {
  count = local.aws_enabled ? 1 : 0

  name = "${var.repository_name}-terraform-deployment"
  role = aws_iam_role.apply[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "IdentifyAccount"
          Effect   = "Allow"
          Action   = "sts:GetCallerIdentity"
          Resource = "*"
        },
        {
          Sid      = "ListTerraformState"
          Effect   = "Allow"
          Action   = "s3:ListBucket"
          Resource = local.aws_state_bucket_arn
          Condition = {
            StringLike = {
              "s3:prefix" = [var.aws.state_key, local.aws_state_lock_key]
            }
          }
        },
        {
          Sid    = "ReadWriteTerraformState"
          Effect = "Allow"
          Action = ["s3:GetObject", "s3:PutObject"]
          Resource = [
            "${local.aws_state_bucket_arn}/${var.aws.state_key}",
            "${local.aws_state_bucket_arn}/${local.aws_state_lock_key}",
          ]
        },
        {
          Sid      = "DeleteTerraformLock"
          Effect   = "Allow"
          Action   = "s3:DeleteObject"
          Resource = "${local.aws_state_bucket_arn}/${local.aws_state_lock_key}"
        },
      ],
      jsondecode(var.aws.apply_policy_statements),
      [
        {
          Sid    = "ReadAutomationRoles"
          Effect = "Allow"
          Action = [
            "iam:GetRole",
            "iam:GetRolePolicy",
            "iam:ListAttachedRolePolicies",
            "iam:ListRolePolicies",
            "iam:ListRoleTags",
          ]
          Resource = [aws_iam_role.apply[0].arn, aws_iam_role.plan[0].arn]
        },
        {
          Sid    = "ReadGitHubIdentityProvider"
          Effect = "Allow"
          Action = [
            "iam:GetOpenIDConnectProvider",
            "iam:ListOpenIDConnectProviderTags",
          ]
          Resource = var.oidc_provider_arn
        },
      ]
    )
  })
}

resource "aws_iam_role_policy" "plan" {
  count = local.aws_enabled ? 1 : 0

  name = "${var.repository_name}-terraform-read-only-plan"
  role = aws_iam_role.plan[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "IdentifyAccount"
          Effect   = "Allow"
          Action   = "sts:GetCallerIdentity"
          Resource = "*"
        },
        {
          Sid      = "ListTerraformState"
          Effect   = "Allow"
          Action   = "s3:ListBucket"
          Resource = local.aws_state_bucket_arn
          Condition = {
            StringLike = {
              "s3:prefix" = [var.aws.state_key, local.aws_state_lock_key]
            }
          }
        },
        {
          Sid      = "ReadTerraformState"
          Effect   = "Allow"
          Action   = "s3:GetObject"
          Resource = "${local.aws_state_bucket_arn}/${var.aws.state_key}"
        },
      ],
      jsondecode(var.aws.plan_policy_statements),
      [
        {
          Sid    = "ReadRoles"
          Effect = "Allow"
          Action = [
            "iam:GetRole",
            "iam:GetRolePolicy",
            "iam:ListAttachedRolePolicies",
            "iam:ListRolePolicies",
            "iam:ListRoleTags",
          ]
          Resource = concat([aws_iam_role.apply[0].arn, aws_iam_role.plan[0].arn], var.aws.extra_readable_role_arns)
        },
        {
          Sid    = "ReadGitHubIdentityProvider"
          Effect = "Allow"
          Action = [
            "iam:GetOpenIDConnectProvider",
            "iam:ListOpenIDConnectProviderTags",
          ]
          Resource = var.oidc_provider_arn
        },
      ]
    )
  })
}
