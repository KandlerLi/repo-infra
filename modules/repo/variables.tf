variable "repository_name" {
  description = "Name of the GitHub repository"
  type        = string
}

variable "action_variables" {
  description = "Map of GitHub Actions variables to create"
  type        = map(string)
}

variable "sha_pinning_required" {
  description = "Whether GitHub Actions must pin third-party actions by commit SHA"
  type        = bool
  default     = false
}
