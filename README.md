# Repository Infrastructure

This repository brings GitHub repository configuration and, optionally, that
repository's AWS deploy credentials under Terraform management from a single
place — following the hardening pattern documented in
[`home-infra-docs/docs/repository-security.md`](https://github.com/KandlerLi/home-infra-docs/blob/main/docs/repository-security.md)
(originally derived from the manually-hardened `dyndns` repository) and
absorbing what was previously a separate `aws-account-bootstrap` root.

## Scope

Managed repositories are declared in `config.yml`. Each key becomes a GitHub
repository managed through the shared `./modules/repo` module. Currently
managed:

- `dyndns`, `website`, `aws-budget` — real Terraform/CI repositories,
  public, full branch protection, self-hosted GitHub Actions runner, AWS
  deploy roles
- `home-infra`, `repo-infra`, `terraform-state`,
  `home-infra-ai-context` (archived) — private backup mirrors (`visibility: private`,
  `branch_protection_enabled: false`; single-owner git-history backups
  with no CI, not collaboratively-protected release repos — see
  `config.yml`'s own comment for why mandatory signed-commit PRs would
  only add friction here)

The scratch repository `testing`, previously used to validate the module,
was deleted (removed from `config.yml`, which destroys its
`github_repository` resource along with everything else the module
created for it) once it had served its purpose.

`whoami` has pre-existing manual protection (a disabled branch ruleset,
non-default merge settings, unrestricted Actions permissions) but is
**intentionally excluded** from this root pending an archive/delete decision
for that repository. Do not add it to `config.yml` without a separate,
deliberate decision.

Branch protection is a **hardcoded baseline applied to every managed
repository**, not opt-in — every `config.yml` entry gets one, matching the
existing hardcoded-for-everyone treatment of `sha_pinning_required`. The one
per-repository knob is `required_status_check_contexts`, a list of workflow
job/status names that must pass before merging (empty by default, since a
repository with no CI has nothing to require):

```yaml
dyndns:
  required_status_check_contexts:
    - "Owner approval"
    - "Validate"
    - "Terraform plan"
```

## What the module manages per repository

GitHub side (always):

- `github_repository` — visibility, merge/branch settings, wiki disabled,
  auto-merge disabled
- `github_repository_vulnerability_alerts` — Dependabot security alerts
  enabled
- `github_branch_default` — pins the default branch to `main`. A genuinely
  empty repository has no default branch until its first push, and GitHub
  just uses whatever branch name that push happens to use — found live
  when a new repository's first push, on a branch not named `main`,
  silently became its default instead. GitHub's API can't set the default
  branch to one that doesn't exist yet, so a brand-new repository's very
  first apply may need a second apply (after the first push creates
  `main`) before this actually takes effect.
- `github_branch_protection` — the baseline described above, applied when
  `branch_protection_enabled` is true (the default; false for repos without
  code, like `home-infra-tracker`): no force-pushes or deletions on the default branch,
  required linear history, required signed commits, required conversation
  resolution, admin enforcement (nobody, including the owner, can bypass),
  `required_approving_review_count = 0` native reviews (GitHub cannot let a
  sole owner approve their own PR — see `dyndns`'s `.github/CODEOWNERS`),
  plus a strict required-status-checks list from each repository's
  `required_status_check_contexts` in `config.yml` (empty for repositories
  with no CI)
- `github_actions_variable` — repo-specific variables from `config.yml`, plus
  `AWS_ACCOUNT_ID`/`AWS_ROLE_ARN`/`AWS_PLAN_ROLE_ARN` when AWS access is
  configured (see below)
- `github_repository_environment` — a `production` environment, gated on
  `branch_protection_enabled`. It has no required reviewers any more
  (removed 2026-09-07: the owner already reviews and merges every PR), but
  stays because every apply job's AWS OIDC trust policy requires the
  `environment:production` subject; deleting it would break AWS access
- `github_actions_repository_permissions` — the allowed-Actions allowlist
  (see "GitHub Actions allowlist notes" below) and `sha_pinning_required`
  (hardcoded to `true` for every managed repository)
- `github_workflow_repository_permissions` — default workflow token
  permissions and PR-approval restriction

`pull_request_creation_policy` and fork-PR approval have no provider
resource yet; `pr_policy.tf` manages both, see "PR creation and fork
approval policy" below.

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

Runner side: **not managed by Terraform at all**. A repository entry may set
`runner: true`, but this module never reads that key — it exists purely as a
convention for `home-infra`'s `scripts/sync_github_runner_repositories.py` to
read (see "Adding a repository with a self-hosted GitHub Actions runner"
below). Attaching a self-hosted runner to a repository is inherently
imperative (obtain a registration token, run `config.sh` against the runner
VM), which Terraform's GitHub provider has no resource for — only
`github_actions_runner_group`, an org-level routing construct, exists there.

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

A repository with no entry in `aws_policies.tf` (like `home-infra-docs`)
gets no AWS role at all — `var.aws` is `null` and the module
skips every AWS resource for it.

## Adding a repository with a self-hosted GitHub Actions runner

The runner VM itself is provisioned and configured by `home-infra`'s
`github_runner` Ansible role, entirely separately from this Terraform root.
This root only holds the `runner: true` convention key that tells
`home-infra` which repositories should get one:

1. Add `runner: true` to the repository's entry in `config.yml`.
2. In [`home-infra`](https://github.com/KandlerLi/home-infra), run
   `.venv/bin/python scripts/sync_github_runner_repositories.py`. This
   regenerates
   `ansible/inventory/group_vars/all/github_runner_repositories.yml` from
   every `config.yml` entry with `runner: true`.
3. Review the diff and commit it in `home-infra`.
4. Run the `github-runner.yml` playbook to register and start the runner
   process for the new repository (it registers each repository's runner
   with its own service user/systemd unit on the shared runner VM — see that
   role's `defaults/main.yml` for details).

This is a two-tool workflow by design: Terraform manages declarative GitHub/
AWS state, but attaching a runner process to a repository is imperative and
stays with Ansible. `config.yml` is still the single place you decide which
repositories exist and what they get.

## Adding a repository that already has manual configuration

1. Read its current live settings with `gh api repos/{owner}/{repo}` and the
   related Actions/rulesets/environment endpoints (and, for AWS, `aws iam
   get-role`/`get-role-policy` if it already has hand-created deploy roles).
2. Add it to `config.yml` (and `aws_policies.tf` if it has AWS access) with
   values matching its live configuration exactly, so the import in the next
   step is zero-diff.
3. Add temporary `import { to = ..., id = ... }` blocks in `main.tf` for each
   resource that already exists live. IAM role import IDs are the role name;
   inline role policy import IDs are `<role-name>:<policy-name>`; a
   `github_branch_protection` import ID is `<repository>:<pattern>` (e.g.
   `dyndns:main`) — **use `repository_id = github_repository.this.node_id`
   in the resource, not `.name`**, or the import will show a forced
   replacement on the next plan (the provider normalizes `repository_id` to
   the GraphQL node ID once a protection rule exists, and a name-vs-node_id
   mismatch reads as a value change).
4. Run `terraform plan` and confirm it shows only imports — zero creates,
   changes, or destroys beyond expected cosmetic attribute updates (e.g. an
   IAM role `description` field). Any unexpected diff — especially to a
   trust policy (`assume_role_policy`) — is a stop condition; re-check the
   live values before applying.
5. `terraform apply`, then delete the now-satisfied `import` blocks.

## Required status check names

A repository whose `checks.yml` calls a gha-common reusable workflow from
a job named `terraform` reports its checks as `terraform / Validate` and
`terraform / Terraform plan`: GitHub prefixes a reusable workflow's jobs
with the caller job's id in every check context. Listing the un-prefixed
names in `required_status_check_contexts` leaves a PR green but
unmergeable, waiting for checks no run will ever report (found live on
`aws-budget`'s first migration PR). The same applies to
`trivy-config / Trivy config scan` and `gitleaks / Gitleaks secret scan`,
including in `k3s-apps`, whose own inline checks are un-prefixed.

## GitHub Actions allowlist notes

`github_actions_repository_permissions` allows the same list of actions
in every managed repository. What it took to get that list right:

- Reusable workflows are governed by the same allowlist. A caller of a
  gha-common workflow missing from the list fails with `startup_failure`
  before running a step.
- Entries match by exact workflow path, not by owning repository, so each
  gha-common workflow (`terraform-checks.yml`, `trivy-config.yml`,
  `trivy-image.yml`, `gitleaks.yml`, ...) needs its own entry.
- Every action a workflow runs transitively counts, not just the
  top-level reference: `aquasecurity/trivy-action` needs its nested
  `setup-trivy`, which needs `actions/cache/restore` and
  `actions/cache/save` as separate entries (`actions/cache@*` alone
  doesn't cover them).
- `actions/github-script` is there for the plan comment on PRs
  (gha-common's `terraform-checks.yml` and `k3s-apps`' own checks); without
  it `k3s-apps#87` hit `startup_failure`.

## IAM policy notes

`aws_policies.tf` holds each repository's deploy permissions beyond the
state-bucket baseline `modules/repo` grants. Two kinds of non-obvious
entries recur there, almost all found live as an AccessDenied:

**Actions the AWS provider calls without the config asking for them.**

- `secretsmanager:GetResourcePolicy` on every refresh of a secret, and
  `secretsmanager:UpdateSecret` to edit an existing container
  (`CreateSecret` doesn't cover it).
- `budgets:ViewBudget` is the IAM action behind the `DescribeBudget` API;
  `Describe*`-named actions don't exist for Budgets and silently grant
  nothing. Reading a budget also always calls `ListTagsForResource`.
- An `aws_s3_bucket` refresh checks the full set of bucket-level settings
  (`GetBucketAcl`, `GetBucketCORS`, ...), whichever ones the config sets.
- CloudFront Functions need `PublishFunction` when `publish = true`, and
  the plan role needs `DescribeFunction`/`GetFunction` to refresh one.
- An `aws_kms_alias` resource, and every `data "aws_kms_alias"` lookup,
  needs `kms:ListAliases`; referencing a key from config needs
  `kms:DescribeKey`; setting `kms_key_id` on an existing log group needs
  `logs:AssociateKmsKey` (see `home-infra-docs`' decisions.md).

**Where `Resource = "*"` is unavoidable.** CloudFront distributions and
OAC; anything whose ID only exists after creation (`acm:RequestCertificate`,
budget creation, Route53 health checks, `kms:CreateKey`); `kms:ListAliases`;
SES v1 identity actions (denied under identity-ARN scoping even with the
right ARN, confirmed three times); and `ses:SendEmail` for the
rotation-reminder mail, scoped to `identity/*` because SES also checks
the external recipient's identity ARN, which this account can never own.
The action stays exactly `ses:SendEmail`.

**Design choices.**

- `k3s-apps` gets the same secret reads for plan and apply: the values
  flow into its Terraform, so a plan needs `GetSecretValue` too.
- Write access for scheduled jobs (the blocky password rotation, the
  rotation reminder) is apply-only and in its own statement, so a leaked
  token reaches exactly that one permission.
- `secrets-manager`'s CI only creates and describes empty containers
  under its three name prefixes, never touching a secret value.
- IAM-user statements (`dyndns`' ACME user, `ses-relay`'s SMTP user) are
  scoped to that one user, never `"*"`. Each user sits in a single-member
  group for trivy AWS-0143; `AddUserToGroup`/`RemoveUserFromGroup` need
  permission on the group only.
- The shared KMS key is resolved by alias in this root, so the real ARN
  lands in each policy and follows the key if it is ever recreated.

**Leftover to remove.** `website`'s `ManageSiteBucket` and
`ReadSiteBucket` still list the `jkandler-website` bucket ARNs from a
bucket rename that was abandoned (ADR 0022); the bucket stays
`www.jkandler.de`. Removing them is an IAM change to apply deliberately,
not part of a comment cleanup.

## PR creation and fork approval policy

`pr_policy.tf` manages two settings `terraform-provider-github` has no
resource for (upstream #3198): who may open a pull request, and which
fork PRs need the owner's approval before their workflows run. Both keep
strangers' code off the self-hosted runners every public repo here uses.
A data source reads the live value on every plan, and a `terraform_data`
keyed on "is it correct?" runs the `gh api` fix only when it isn't, so
plan shows drift and apply corrects it (a bare `local-exec` without the
read is not acceptable, see `home-infra-docs`' decisions.md). After a
fix the next plan shows one harmless replacement as the trigger flips
back; the command is idempotent. A repository created or made public in
the same apply reads as not yet correct, so its fix runs after the
repository change. Needs a `gh` CLI with admin rights on these repos.

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
cd repo-infra
terraform fmt -check -recursive
terraform validate
terraform plan
```

Provider authentication is supplied through environment variables at
invocation time: `GITHUB_TOKEN` (and the target GitHub owner) for the GitHub
provider, and `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/(session token) for
a short-lived AWS identity capable of managing IAM roles/policies and the
OIDC provider. There is no committed provider configuration for either.

## Rolling out locally

`scripts/roll-out.sh plan`/`apply` does all of the above in one command --
pulls `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` for the `repo-infra-local`
IAM identity from `pass` (see [`terraform-state/README.md`](https://github.com/KandlerLi/terraform-state/blob/main/README.md)'s
"repo-infra-local Identity" section for how that identity and its `pass`
entries get created) and `GITHUB_TOKEN` from `gh auth token`, runs
`terraform fmt -check`/`validate`/`plan`, and for `apply` mode
`terraform apply` (left interactive -- Terraform's own plan-and-confirm
prompt is the review step). Everything it exports lives only inside the
script's own process; nothing persists in the calling shell afterward.
