output "name" {
  description = "Repository name, known at plan time once the repository exists."
  value       = github_repository.this.name
}
