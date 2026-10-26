# Authoritative: a label created only with gh is deleted by the next apply. The scheme: maintain-tracker skill.
resource "github_issue_labels" "tracker" {
  repository = module.repo["home-infra-tracker"].name

  label {
    name        = "ready"
    color       = "0e8a16"
    description = "Can be started now, nothing blocks it"
  }

  label {
    name        = "waiting"
    color       = "fbca04"
    description = "Waits on something outside (hardware, a recurrence, a condition); the body says what ends the wait"
  }

  label {
    name        = "idea"
    color       = "c5def5"
    description = "Not decided whether to do it at all"
  }

  label {
    name        = "size: S"
    color       = "d4c5f9"
    description = "Under an hour, one repo, no apply or a trivial one"
  }

  label {
    name        = "size: M"
    color       = "a37cf0"
    description = "About one session, a PR or two, maybe an apply"
  }

  label {
    name        = "size: L"
    color       = "5319e7"
    description = "Several sessions, several repos, or hands-on work"
  }

  label {
    name        = "SSD"
    color       = "1d76db"
    description = "Affected by or depends on the move to the new SSD (VM disks off the HDD)"
  }
}
