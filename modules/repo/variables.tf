variable "repository_name" {
  description = "Name of the GitHub repository"
  type        = string
}

variable "action_variables" {
  description = "Map of GitHub Actions variables to create"
  type        = map(string)
}

variable "aws" {
  description = "Optional AWS deploy-role configuration for this repository. Omit (null) for repositories that don't deploy to AWS."
  type = object({
    state_key                = string
    extra_readable_role_arns = optional(list(string), [])
    # JSON-encoded list of IAM statement objects. Passed as a JSON string
    # rather than list(any) because IAM statements have heterogeneous shapes
    # (Resource is sometimes a string, sometimes a list; Condition is only
    # present on some statements), which Terraform's type system can't
    # unify into a single list(object(...)) type across a module boundary.
    apply_policy_statements = optional(string, "[]")
    plan_policy_statements  = optional(string, "[]")
  })
  default = null
}

variable "oidc_provider_arn" {
  description = "ARN of the account-wide GitHub Actions OIDC provider"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID hosting the deploy roles"
  type        = string
}

variable "github_owner" {
  description = "GitHub account/organization login used in the OIDC trust subject"
  type        = string
  default     = "KandlerLi"
}

variable "github_owner_id" {
  description = "Immutable numeric GitHub ID of the account/organization"
  type        = string
  default     = "24520951"
}
