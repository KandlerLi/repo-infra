# GitHub Repository Protection

This repository brings GitHub repository protection settings under Terraform
management, following the pattern documented in
`/home/julian/projects/home-infra-ai-context/context/repository-security-blueprint.md`
(originally derived from the manually-hardened `dyndns` repository).

## Scope

Managed repositories are declared in `config.yml`. Each key becomes a GitHub
repository managed through the shared `./modules/repo` module. Currently
managed:

- `dyndns` — the real DynDNS Terraform/CI repository
- `testing` — a scratch repository used to validate the module

`whoami` has pre-existing manual protection (a disabled branch ruleset,
non-default merge settings, unrestricted Actions permissions) but is
**intentionally excluded** from this root pending an archive/delete decision
for that repository. Do not add it to `config.yml` without a separate,
deliberate decision.

## What the module manages per repository

- `github_repository` — visibility, merge/branch settings
- `github_repository_ruleset` — a default-branch ruleset (currently
  `enforcement = "disabled"`)
- `github_actions_variable` — `AWS_ACCOUNT_ID`, `AWS_PLAN_ROLE_ARN`,
  `AWS_ROLE_ARN`, plus any repo-specific variables from `config.yml`
- `github_repository_environment` — a `production` environment requiring
  owner review
- `github_actions_repository_permissions` — the allowed-Actions allowlist
  (`actions/checkout@*`, `aws-actions/configure-aws-credentials@*`,
  `hashicorp/setup-terraform@*`) and `sha_pinning_required` (hardcoded to
  `true` for every managed repository — see
  `dyndns/scripts/protect-repository.sh` for the same baseline applied
  manually before this root existed)
- `github_workflow_repository_permissions` — default workflow token
  permissions and PR-approval restriction

`sha_pinning_required` and `github_workflow_repository_permissions` had both
been set manually through the GitHub web UI before this Terraform root
existed and have since been imported into state.

Not managed here: the account-wide GitHub OIDC provider and the AWS
plan/apply IAM roles/policies referenced by the Actions variables above —
those live in `/home/julian/projects/aws-account-bootstrap`.

## Adding a repository that already has manual configuration

1. Read its current live settings with `gh api repos/{owner}/{repo}` and the
   related Actions/rulesets/environment endpoints.
2. Add it to `config.yml` with values matching its live configuration.
3. Add temporary `import { to = ..., id = ... }` blocks in `main.tf` for each
   resource that already exists live.
4. Run `terraform plan` and confirm it shows only imports — zero creates,
   changes, or destroys. Any unexpected diff is a stop condition; re-check the
   live values before applying.
5. `terraform apply`, then delete the now-satisfied `import` blocks.

## State

This root currently uses Terraform's default **local** backend
(`terraform.tfstate`, git-ignored) rather than the shared encrypted S3 backend
used by the rest of this workspace's Terraform roots. This is a known,
deliberately deferred gap — migrate to the shared backend before treating
this root as production-critical.

## Validation

```bash
cd /home/julian/projects/github-infra
terraform fmt -check -recursive
terraform validate
terraform plan
```

Provider authentication (`GITHUB_TOKEN`, and the target owner) is supplied
through environment variables at invocation time; there is no committed
provider configuration.
