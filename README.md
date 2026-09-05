# Repository Infrastructure

This repository brings GitHub repository configuration and, optionally, that
repository's AWS deploy credentials under Terraform management from a single
place — following the hardening pattern documented in
`/home/julian/projects/docs/home-infra-ai-context/context/repository-security-blueprint.md`
(originally derived from the manually-hardened `dyndns` repository) and
absorbing what was previously a separate `aws-account-bootstrap` root.

## Scope

Managed repositories are declared in `config.yml`. Each key becomes a GitHub
repository managed through the shared `./modules/repo` module. Currently
managed:

- `dyndns`, `website`, `aws-budget` — real Terraform/CI repositories,
  public, full branch protection, self-hosted GitHub Actions runner, AWS
  deploy roles
- `home-infra`, `repo-infra`, `terraform-state`, `home-infra-docs`,
  `home-infra-ai-context` — private backup mirrors (`visibility: private`,
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
  `branch_protection_enabled` is true (the default; false for the private
  backup mirrors): no force-pushes or deletions on the default branch,
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
- `github_repository_environment` — a `production` environment requiring
  owner review, also gated on `branch_protection_enabled` (GitHub's
  required-reviewers environment protection needs a paid plan for private
  repositories — found live when this unconditionally applied to the
  private backup mirrors)
- `github_actions_repository_permissions` — the allowed-Actions allowlist
  (`actions/checkout@*`, `aws-actions/configure-aws-credentials@*`,
  `hashicorp/setup-terraform@*`) and `sha_pinning_required` (hardcoded to
  `true` for every managed repository)
- `github_workflow_repository_permissions` — default workflow token
  permissions and PR-approval restriction

**Not managed here**: `pull_request_creation_policy` (the setting that
actually restricts who can *open* a PR at all — GitHub added this in Feb
2026 and `terraform-provider-github` has no resource for it yet; tracked as
unimplemented feature requests
[#3251](https://github.com/integrations/terraform-provider-github/issues/3251)
and
[#3198](https://github.com/integrations/terraform-provider-github/issues/3198)).
It used to be set, once per repository, by `dyndns/scripts/protect-repository.sh`
— the one remaining piece of that script, kept only because there is
currently no IaC path for this specific field. That script was deleted on
2026-09-02 (even narrowed to this one setting plus collaborator pruning, it
was still an imperative script wrapping `gh api` against live state, which
the standing IaC-only rule forbids); see
`home-infra-ai-context/context/repository-security-blueprint.md` for the
manual `gh api` command to apply this by hand instead. Revisit once the
provider adds support.

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

A repository with no entry in `aws_policies.tf` (like the private backup
mirrors) gets no AWS role at all — `var.aws` is `null` and the module
skips every AWS resource for it.

## Adding a repository with a self-hosted GitHub Actions runner

The runner VM itself is provisioned and configured by `home-infra`'s
`github_runner` Ansible role, entirely separately from this Terraform root.
This root only holds the `runner: true` convention key that tells
`home-infra` which repositories should get one:

1. Add `runner: true` to the repository's entry in `config.yml`.
2. In `/home/julian/projects/infra/home-infra`, run
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
cd /home/julian/projects/github/repo-infra
terraform fmt -check -recursive
terraform validate
terraform plan
```

Provider authentication is supplied through environment variables at
invocation time: `GITHUB_TOKEN` (and the target GitHub owner) for the GitHub
provider, and `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/(session token) for
a short-lived AWS identity capable of managing IAM roles/policies and the
OIDC provider. There is no committed provider configuration for either.
