# The two labels replacing PARKED/BACKLOG; GitHub's default labels are removed on purpose.
resource "github_issue_labels" "tracker" {
  repository = module.repo["home-infra-tracker"].name

  label {
    name        = "parked"
    color       = "d93f0b"
    description = "Set aside but with real pull to pick up soon"
  }

  label {
    name        = "backlog"
    color       = "c5def5"
    description = "Known gap, nobody chasing it right now"
  }
}
