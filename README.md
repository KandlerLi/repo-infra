# Repository Infrastructure

This repository brings GitHub repository configuration and, optionally, that
repository's AWS deploy credentials under Terraform management from a single
place — following the hardening pattern documented in
`/home/julian/projects/home-infra-ai-context/context/repository-security-blueprint.md`
(originally derived from the manually-hardened `dyndns` repository) and
absorbing what was previously a separate `aws-account-bootstrap` root.

## Scope

Managed repositories are declared in `config.yml`. Each key becomes a GitHub
repository managed through the shared `./modules/repo` module. Currently
managed:

- `dyndns` — the real DynDNS Terraform/CI repository (GitHub settings + AWS
  deploy roles)
- `testing` — a scratch repository used to validate the module (GitHub
  settings only, no AWS access)

`whoami` has pre-existing manual protection (a disabled branch ruleset,
non-default merge settings, unrestricted Actions permissions) but is
**intentionally excluded** from this root pending an archive/delete decision
for that repository. Do not add it to `config.yml` without a separate,
deliberate decision.

## What the module manages per repository

GitHub side (always):

- `github_repository` — visibility, merge/branch settings
- `github_repository_ruleset` — a default-branch ruleset (currently
  `enforcement = "disabled"`)
- `github_actions_variable` — repo-specific variables from `config.yml`, plus
  `AWS_ACCOUNT_ID`/`AWS_ROLE_ARN`/`AWS_PLAN_ROLE_ARN` when AWS access is
  configured (see below)
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

AWS side (only for repositories with an entry in `aws_policies.tf`, e.g.
`dyndns`):

- The account-wide GitHub Actions OIDC provider (`aws_iam_openid_connect_provider.github`,
  a single root-level resource, not per-repository)
- `aws_iam_role` (apply + plan), trust policy scoped to that repository's
  `environment:production` / `pull_request` OIDC subject
- `aws_iam_role_policy` (apply + plan): a generic baseline (state-bucket
  access, self-role/OIDC-provider read) plus that repository's own IAM
  statements from `aws_policies.tf`
- The `AWS_ACCOUNT_ID`/`AWS_ROLE_ARN`/`AWS_PLAN_ROLE_ARN` Actions variables
  above, set from the real created role ARNs — not a guessed ARN string or a
  manually-pasted GitHub UI value

## Adding a new repository that deploys to AWS

This is the workflow the consolidation exists for — one repository, one
`terraform apply`:

1. Add an entry to `config.yml` (GitHub-side settings, same as any other
   managed repository).
2. Add a matching entry to `aws_policies.tf`'s `local.aws_policies` map with
   that repository's own `state_key` and the IAM statements its deployment
   needs (`apply_policy_statements`/`plan_policy_statements`). AWS
   permissions are inherently deployment-specific and can't be derived
   automatically — this is the one thing you still have to write yourself.
   Everything else (OIDC trust, state-bucket access, role creation, and
   wiring the resulting ARNs into the repo's Actions variables) is automatic.
3. `terraform plan`, review, `terraform apply`.

A repository with no entry in `aws_policies.tf` (like `testing`) gets no AWS
role at all — `var.aws` is `null` and the module skips every AWS resource for
it.

## Adding a repository that already has manual configuration

1. Read its current live settings with `gh api repos/{owner}/{repo}` and the
   related Actions/rulesets/environment endpoints (and, for AWS, `aws iam
   get-role`/`get-role-policy` if it already has hand-created deploy roles).
2. Add it to `config.yml` (and `aws_policies.tf` if it has AWS access) with
   values matching its live configuration exactly, so the import in the next
   step is zero-diff.
3. Add temporary `import { to = ..., id = ... }` blocks in `main.tf` for each
   resource that already exists live. IAM role import IDs are the role name;
   inline role policy import IDs are `<role-name>:<policy-name>`.
4. Run `terraform plan` and confirm it shows only imports — zero creates,
   changes, or destroys beyond expected cosmetic attribute updates (e.g. an
   IAM role `description` field). Any unexpected diff — especially to a
   trust policy (`assume_role_policy`) — is a stop condition; re-check the
   live values before applying.
5. `terraform apply`, then delete the now-satisfied `import` blocks.

## State

State lives in the shared encrypted S3 backend (`jkandler-terraform-state`,
key `repo-infra/terraform.tfstate`), the same bucket used by every other
Terraform root in this workspace. This root now owns the account-wide GitHub
Actions OIDC provider and per-repository AWS IAM deploy roles (absorbed from
the retired `aws-account-bootstrap` root on 2026-08-21), so — like that root
was — it must be run only from a trusted local controller with a
human-selected, short-lived AWS identity, never through GitHub Actions or a
role it manages. `prevent_destroy` is set on the OIDC provider and both IAM
roles; never remove it without an explicitly approved design change.

## Validation

```bash
cd /home/julian/projects/repo-infra
terraform fmt -check -recursive
terraform validate
terraform plan
```

Provider authentication is supplied through environment variables at
invocation time: `GITHUB_TOKEN` (and the target GitHub owner) for the GitHub
provider, and `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/(session token) for
a short-lived AWS identity capable of managing IAM roles/policies and the
OIDC provider. There is no committed provider configuration for either.
