variable "repository_name" {
  description = "Name of the GitHub repository"
  type        = string
}

variable "action_variables" {
  description = "Map of GitHub Actions variables to create"
  type        = map(string)
}
