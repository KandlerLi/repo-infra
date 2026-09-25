# Per-repository AWS deploy-role configuration. AWS IAM permissions are
# inherently deployment-specific and can't be derived automatically, so this
# is the one thing a new AWS-deploying repository still requires real
# Terraform code (not plain config.yml) for: state-bucket access is handled
# generically by modules/repo, everything below is what that specific
# repository's deployment needs beyond that baseline.
#
# To add AWS access for a new repository: add its entry to config.yml, then
# add a matching entry here with its state key and the IAM statements its
# deployment needs. See README.md for the full walkthrough.

# bootstrap/terraform-state's own shared CMK (shared_kms_key.tf), looked
# up by its fixed alias rather than threaded through as a repository
# variable -- this root's own local-apply credentials already have
# enough access for the lookup (same admin-equivalent identity that
# applies this whole repo), and resolving it here bakes the real ARN
# into whichever repo's IAM policy needs kms:DescribeKey below,
# self-updating if the key ever gets recreated instead of needing a
# manually-copied value kept in sync by hand.
data "aws_kms_alias" "shared" {
  name = "alias/shared"
}

locals {
  aws_region = "eu-central-1"

  # k3s-apps' own read access to the Secrets Manager groups its
  # Terraform reads directly (data "aws_secretsmanager_secret_version",
  # k3s-apps' own secrets.tf). Deliberately identical for apply AND
  # plan: unlike dyndns's own ManageDynDnsSecret/ReadDynDnsSecretMetadata
  # split (where the plan role never needs the real value, since that
  # secret is Lambda-runtime-only), these values flow directly into
  # Terraform's own jsondecode() locals, so even a plan needs
  # GetSecretValue to compute a diff, not just DescribeSecret. ARNs are
  # hand-built with a trailing "-*" wildcard for the random suffix
  # Secrets Manager appends, matching dyndns's own established
  # convention -- these are a different repo's own resources
  # (aws/secrets-manager), so there's no real Terraform resource
  # reference to use here the way that repo's own operator.tf could.
  # Excludes home-infra/nextcloud (Ansible-only, infra/home-infra never
  # touches this repo) and home-infra/github-runner
  # (bootstrap/k3s-bootstrap's own, not k3s-apps').
  k3s_apps_secretsmanager_read_statements = [
    {
      Sid    = "ReadSecretsManagerSecrets"
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = [
        "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:home-infra/authelia-*",
        "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:home-infra/grafana-*",
        "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:home-infra/open-webui-*",
        "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:home-infra/ingress-*",
        "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:home-infra/home-agent-*",
        "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:home-infra/monitoring-*",
        "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:home-infra/blocky-*",
        "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:k3s-apps/sankey-export-*",
        "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:k3s-apps/ghcr-pull-token-*",
        # k3s-apps/bulwark: a genuinely new secret, not a migration --
        # Bulwark webmail's own Authelia OIDC client secret (plaintext
        # half; home-infra/authelia holds the matching hash).
        "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:k3s-apps/bulwark-*",
        # k3s-apps/stalwart: the Stalwart management-API token the
        # Stalwart Terraform provider authenticates with.
        "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:k3s-apps/stalwart-*",
        # k3s-apps/paperless: Paperless-ngx's own Authelia OIDC client
        # secret (ADR 0023; plaintext half, hash in home-infra/authelia).
        "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:k3s-apps/paperless-*",
      ]
    },
  ]

  # Write access for the scheduled blocky_postgres_password rotation
  # workflow (infra/k3s-apps' own rotate-blocky-postgres.yml) -- the
  # only secret this CI role can ever write, and apply-only, matching
  # dyndns's own ManageDynDnsSecret/ReadDynDnsSecretMetadata split
  # above (a plan never needs to write anything). Deliberately its own
  # statement, not folded into the broad read list, so the blast
  # radius of a compromised token is exactly one secret's write access,
  # not every secret this role can read.
  k3s_apps_blocky_rotation_statement = [
    {
      Sid      = "RotateBlockyPostgresPassword"
      Effect   = "Allow"
      Action   = "secretsmanager:PutSecretValue"
      Resource = "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:home-infra/blocky-*"
    },
  ]

  # aws/secrets-manager's own CI role, added 2026-09-13 once this
  # root's real risk profile turned out not to match terraform-state/
  # k3s-bootstrap's (see that repo's own README): it never touches IAM,
  # only ever creates or updates empty aws_secretsmanager_secret
  # *containers* under the three name prefixes it already manages --
  # never GetSecretValue, PutSecretValue, or DeleteSecret, none of
  # which this repo's Terraform ever calls. CreateSecret/UpdateSecret
  # are the only real write permissions, scoped to exactly these
  # prefixes so a compromised run can create a bogus empty container or
  # rewrite one's own description/recovery window at worst, never touch
  # an actual secret value or anywhere outside them. Identical for plan
  # and apply -- a speculative plan never actually creates or updates
  # anything regardless of what it's allowed to, and a plan still needs
  # the same read actions apply does to refresh state. DescribeSecret
  # alone wasn't enough -- found live on this PR's own first real plan
  # run: the AWS provider's aws_secretsmanager_secret read also calls
  # GetResourcePolicy on every refresh (checking for a resource-based
  # policy, whether or not one exists), a separate IAM action neither
  # this repo's own Terraform nor DescribeSecret's own name would
  # suggest -- same category of gap ADR 0018 already anticipated
  # (SNS/Budgets hit the same "the real API surface needs more than the
  # obviously-named action" pattern before). UpdateSecret specifically
  # was missing the same way: this repo's Terraform had only ever
  # *created* containers until a later PR edited two existing
  # descriptions, and CreateSecret alone doesn't cover updating an
  # already-existing resource -- confirmed live, that apply failed with
  # AccessDeniedException on secretsmanager:UpdateSecret before this
  # was added.
  secrets_manager_statements = [
    {
      Sid    = "ManageSecretContainers"
      Effect = "Allow"
      Action = [
        "secretsmanager:CreateSecret",
        "secretsmanager:UpdateSecret",
        "secretsmanager:DescribeSecret",
        "secretsmanager:GetResourcePolicy",
      ]
      Resource = [
        "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:home-infra/*",
        "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:k3s-apps/*",
        "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:dyndns/*",
      ]
    },
  ]

  # For the scheduled rotation-reminder workflow (check-secret-rotation.yml,
  # BACKLOG.md's "Manually-rotated Secrets Manager secrets have no
  # rotation reminder") -- same shape as k3s_apps_blocky_rotation_statement
  # above: a scheduled job's own extra permission, apply-only, added as
  # its own narrow statement rather than folded into the broad read/
  # manage list. Resource is a wildcard, not scoped to jkandler.de (aws/
  # ses-relay's own verified SES domain identity) alone -- confirmed
  # live 2026-09-17 this has to be: AWS's own ses:SendEmail IAM
  # authorization checks the caller's policy against an identity ARN
  # constructed from the *destination* address too, not just the
  # sender's, and the real recipient here (julian.kandler@outlook.com)
  # is an external address this account will never own or verify, so
  # there's no specific destination ARN to enumerate in advance the way
  # the sender's own identity/jkandler.de could be. Action stays scoped
  # to exactly ses:SendEmail (no ses:*), so a compromised token can
  # still only ever send mail through this account's own SES sending
  # limits, never touch identity verification, configuration sets, or
  # anything else SES exposes.
  secrets_manager_rotation_check_statement = [
    {
      Sid      = "SendRotationReminderEmail"
      Effect   = "Allow"
      Action   = "ses:SendEmail"
      Resource = "arn:aws:ses:${local.aws_region}:${data.aws_caller_identity.current.account_id}:identity/*"
    },
  ]

  aws_policies = {
    # k3s-apps manages zero real AWS resources of its own -- this
    # entry's own baseline exists purely so its CI can read/write its
    # own Terraform state in S3 (added 2026-09-03 alongside moving that
    # root to a real backend; everything it actually manages lives in
    # the k3s cluster, reached via an in-cluster ServiceAccount, not AWS
    # credentials at all). Secrets Manager read access (above) is the
    # one real exception -- added once this root's own Terraform started
    # reading secret values directly instead of taking them as
    # GitHub-Actions-secret-sourced TF_VAR_* input. PutSecretValue on
    # home-infra/blocky specifically (also above) is apply-only, added
    # 2026-09-12 for the scheduled rotation workflow.
    k3s-apps = {
      state_key = "k3s-apps/terraform.tfstate"
      apply_policy_statements = concat(
        local.k3s_apps_secretsmanager_read_statements,
        local.k3s_apps_blocky_rotation_statement,
      )
      plan_policy_statements = local.k3s_apps_secretsmanager_read_statements
    }

    dyndns = {
      state_key = "dyndns/terraform.tfstate"

      # The Lambda runtime role dyndns' own Terraform manages; the deploy
      # role needs to introspect it (see ManageLambdaRole below).
      extra_readable_role_arns = [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/dyndns-route53-updater-role",
      ]

      apply_policy_statements = [
        {
          Sid      = "ManageApiGateway"
          Effect   = "Allow"
          Action   = "apigateway:*"
          Resource = "arn:aws:apigateway:${local.aws_region}::*"
        },
        {
          Sid    = "ManageLambda"
          Effect = "Allow"
          Action = "lambda:*"
          Resource = [
            "arn:aws:lambda:${local.aws_region}:${data.aws_caller_identity.current.account_id}:function:dyndns-route53-updater",
            "arn:aws:lambda:${local.aws_region}:${data.aws_caller_identity.current.account_id}:function:dyndns-route53-updater:*",
          ]
        },
        {
          Sid    = "ManageLogs"
          Effect = "Allow"
          Action = [
            "logs:CreateLogGroup",
            "logs:DeleteLogGroup",
            "logs:ListTagsForResource",
            "logs:PutRetentionPolicy",
            "logs:TagResource",
            "logs:UntagResource",
            # Setting kms_key_id on an *existing* aws_cloudwatch_log_group
            # calls this AWS API directly -- distinct from anything above,
            # and distinct from the kms:* grants below (those cover using
            # the key itself, not associating/disassociating it with a log
            # group). See docs/home-infra-ai-context's decisions.md for
            # the AccessDeniedException this grant closes.
            "logs:AssociateKmsKey",
            "logs:DisassociateKmsKey",
          ]
          Resource = [
            "arn:aws:logs:${local.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/dyndns-route53-updater",
            "arn:aws:logs:${local.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/dyndns-route53-updater:*",
            "arn:aws:logs:${local.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/apigateway/dyndns",
            "arn:aws:logs:${local.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/apigateway/dyndns:*",
          ]
        },
        {
          Sid      = "DescribeLogs"
          Effect   = "Allow"
          Action   = "logs:DescribeLogGroups"
          Resource = "*"
        },
        {
          Sid      = "ManageDynDnsSecret"
          Effect   = "Allow"
          Action   = "secretsmanager:*"
          Resource = "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:dyndns/fritzbox-*"
        },
        {
          Sid    = "ManageDns"
          Effect = "Allow"
          Action = [
            "route53:ChangeResourceRecordSets",
            "route53:GetHostedZone",
            "route53:ListResourceRecordSets",
            "route53:ListTagsForResource",
          ]
          Resource = "arn:aws:route53:::hostedzone/Z07879811I86VC8PAL8HX"
        },
        {
          Sid      = "ReadDnsChanges"
          Effect   = "Allow"
          Action   = "route53:GetChange"
          Resource = "arn:aws:route53:::change/*"
        },
        {
          Sid    = "ManageLambdaRole"
          Effect = "Allow"
          Action = [
            "iam:CreateRole",
            "iam:DeleteRole",
            "iam:DeleteRolePolicy",
            "iam:GetRole",
            "iam:GetRolePolicy",
            "iam:ListAttachedRolePolicies",
            "iam:ListRolePolicies",
            "iam:ListRoleTags",
            "iam:PassRole",
            "iam:PutRolePolicy",
            "iam:TagRole",
            "iam:UntagRole",
            "iam:UpdateAssumeRolePolicy",
            "iam:UpdateRoleDescription",
          ]
          Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/dyndns-route53-updater-role"
        },
        {
          # Same shape as ses-relay's own ManageSmtpUser statement below
          # -- scoped to exactly the one dedicated user this deployment
          # creates, never a bare "*", so this role can manage that
          # user's own access key but no other IAM principal.
          Sid    = "ManageAcmeDns01User"
          Effect = "Allow"
          Action = [
            "iam:CreateUser",
            "iam:GetUser",
            "iam:DeleteUser",
            "iam:TagUser",
            "iam:UntagUser",
            "iam:ListUserTags",
            "iam:PutUserPolicy",
            "iam:GetUserPolicy",
            "iam:DeleteUserPolicy",
            "iam:ListUserPolicies",
            "iam:CreateAccessKey",
            "iam:ListAccessKeys",
            "iam:DeleteAccessKey",
          ]
          Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/traefik-acme-dns01"
        },
        {
          # Fixes trivy's AWS-0143 (policy attached directly to a user,
          # not a group/role) -- moves acme_dns01's own inline policy
          # onto a new group with this one user as its only member.
          # AddUserToGroup/RemoveUserFromGroup only require permission on
          # the group resource, not the user, per IAM's own action
          # reference for these two.
          Sid    = "ManageAcmeDns01Group"
          Effect = "Allow"
          Action = [
            "iam:CreateGroup",
            "iam:DeleteGroup",
            "iam:GetGroup",
            "iam:PutGroupPolicy",
            "iam:GetGroupPolicy",
            "iam:DeleteGroupPolicy",
            "iam:ListGroupPolicies",
            "iam:AddUserToGroup",
            "iam:RemoveUserFromGroup",
          ]
          Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:group/acme-dns01-challenge"
        },
        {
          # Fixes trivy's AWS-0017 (log groups not KMS-encrypted) --
          # kms:DescribeKey is what AWS actually requires of the caller
          # to associate a CMK with a CloudWatch log group (the log
          # group's own encryption at rest is otherwise handled
          # transparently by the CloudWatch Logs service, per the key's
          # own policy in shared_kms_key.tf -- this grant is only about
          # letting this role *reference* the key, not encrypt/decrypt
          # anything itself). kms:ListAliases doesn't support
          # resource-level scoping at all (AWS requires Resource "*"),
          # needed for dyndns's own data "aws_kms_alias" lookup to
          # resolve the same way this file's own lookup above does.
          Sid      = "ReadSharedKmsKey"
          Effect   = "Allow"
          Action   = ["kms:DescribeKey"]
          Resource = data.aws_kms_alias.shared.target_key_arn
        },
        {
          Sid      = "ListKmsAliases"
          Effect   = "Allow"
          Action   = "kms:ListAliases"
          Resource = "*"
        },
      ]

      plan_policy_statements = [
        {
          Sid      = "ReadApiGateway"
          Effect   = "Allow"
          Action   = "apigateway:GET"
          Resource = "arn:aws:apigateway:${local.aws_region}::*"
        },
        {
          Sid    = "ReadLambda"
          Effect = "Allow"
          Action = [
            "lambda:GetFunction",
            "lambda:GetFunctionCodeSigningConfig",
            "lambda:GetPolicy",
            "lambda:ListTags",
            "lambda:ListVersionsByFunction",
          ]
          Resource = [
            "arn:aws:lambda:${local.aws_region}:${data.aws_caller_identity.current.account_id}:function:dyndns-route53-updater",
            "arn:aws:lambda:${local.aws_region}:${data.aws_caller_identity.current.account_id}:function:dyndns-route53-updater:*",
          ]
        },
        {
          Sid      = "DescribeLogs"
          Effect   = "Allow"
          Action   = "logs:DescribeLogGroups"
          Resource = "*"
        },
        {
          Sid    = "ReadLogTags"
          Effect = "Allow"
          Action = "logs:ListTagsForResource"
          Resource = [
            "arn:aws:logs:${local.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/dyndns-route53-updater",
            "arn:aws:logs:${local.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/apigateway/dyndns",
          ]
        },
        {
          Sid    = "ReadDynDnsSecretMetadata"
          Effect = "Allow"
          Action = [
            "secretsmanager:DescribeSecret",
            "secretsmanager:GetResourcePolicy",
            "secretsmanager:ListSecretVersionIds",
          ]
          Resource = "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:dyndns/fritzbox-*"
        },
        {
          Sid    = "ReadDns"
          Effect = "Allow"
          Action = [
            "route53:GetHostedZone",
            "route53:ListResourceRecordSets",
            "route53:ListTagsForResource",
          ]
          Resource = "arn:aws:route53:::hostedzone/Z07879811I86VC8PAL8HX"
        },
        {
          Sid    = "ReadAcmeDns01User"
          Effect = "Allow"
          Action = [
            "iam:GetUser",
            "iam:ListUserTags",
            "iam:GetUserPolicy",
            "iam:ListUserPolicies",
            "iam:ListAccessKeys",
          ]
          Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/traefik-acme-dns01"
        },
        {
          Sid    = "ReadAcmeDns01Group"
          Effect = "Allow"
          Action = [
            "iam:GetGroup",
            "iam:GetGroupPolicy",
            "iam:ListGroupPolicies",
          ]
          Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:group/acme-dns01-challenge"
        },
        {
          Sid      = "ReadSharedKmsKey"
          Effect   = "Allow"
          Action   = ["kms:DescribeKey"]
          Resource = data.aws_kms_alias.shared.target_key_arn
        },
        {
          Sid      = "ListKmsAliases"
          Effect   = "Allow"
          Action   = "kms:ListAliases"
          Resource = "*"
        },
      ]
    }

    website = {
      state_key = "website/terraform.tfstate"

      apply_policy_statements = [
        {
          # Broad action wildcard, tightly scoped resource -- same shape as
          # ManageDynDnsSecret above. Covers bucket lifecycle (create/tag/
          # policy/public-access-block/ownership-controls) plus the object
          # reads/writes the deploy step's `aws s3 sync` needs.
          #
          # Temporarily includes both the old (www.jkandler.de) and new
          # (jkandler-website) bucket ARNs -- fixes trivy's AWS-0320 (bucket
          # name not DNS-compliant) by renaming the bucket, which Terraform
          # can only do as destroy-old + create-new, never in place. This
          # role needs delete access to the old ARN in the very same apply
          # that creates the new one. Remove the www.jkandler.de lines once
          # that apply is confirmed done and the old bucket no longer
          # exists.
          Sid    = "ManageSiteBucket"
          Effect = "Allow"
          Action = "s3:*"
          Resource = [
            "arn:aws:s3:::jkandler-website",
            "arn:aws:s3:::jkandler-website/*",
            "arn:aws:s3:::www.jkandler.de",
            "arn:aws:s3:::www.jkandler.de/*",
          ]
        },
        {
          # Fixes trivy's AWS-0132 (bucket should use a CMK) -- the
          # deploy step's own `aws s3 sync` PutObject calls need
          # kms:GenerateDataKey* against the shared key once the bucket's
          # default encryption switches to it; kms:DescribeKey is what
          # AWS requires just to reference the key from Terraform's own
          # bucket encryption config. See terraform-state#6 for
          # CloudFront's own separate key-policy grant -- this is about
          # this role's own access, not CloudFront's.
          Sid      = "UseSharedKmsKeyForSiteBucket"
          Effect   = "Allow"
          Action   = ["kms:GenerateDataKey*", "kms:Decrypt", "kms:DescribeKey"]
          Resource = data.aws_kms_alias.shared.target_key_arn
        },
        {
          # website's own Terraform resolves the same alias/shared
          # lookup this file's own data source does (to set kms_key_id
          # on aws_s3_bucket_server_side_encryption_configuration) --
          # kms:ListAliases doesn't support resource-level scoping.
          Sid      = "ListKmsAliasesForSiteBucket"
          Effect   = "Allow"
          Action   = "kms:ListAliases"
          Resource = "*"
        },
        {
          # CloudFront does not support resource-level permissions for
          # distribution/OAC lifecycle actions (same reasoning as
          # DescribeLogs above needing Resource "*").
          Sid    = "ManageCloudFront"
          Effect = "Allow"
          Action = [
            "cloudfront:CreateDistribution",
            "cloudfront:GetDistribution",
            "cloudfront:UpdateDistribution",
            "cloudfront:DeleteDistribution",
            "cloudfront:TagResource",
            "cloudfront:UntagResource",
            "cloudfront:ListTagsForResource",
            "cloudfront:CreateOriginAccessControl",
            "cloudfront:GetOriginAccessControl",
            "cloudfront:UpdateOriginAccessControl",
            "cloudfront:DeleteOriginAccessControl",
          ]
          Resource = "*"
        },
        {
          # aws_cloudfront_function.url_rewrite (main.tf, publish =
          # true) failed AccessDenied on
          # cloudfront:CreateFunction -- CloudFront Functions are a
          # genuinely separate action namespace from the
          # distribution/OAC lifecycle ManageCloudFront above already
          # covers, never granted before since this repo never had a
          # Function resource until now. Unlike distributions,
          # CloudFront Functions *do* support resource-level ARNs (the
          # AccessDenied error itself names
          # arn:...:function/www-jkandler-de-url-rewrite) -- scoped to
          # the function/* resource type rather than ManageCloudFront's
          # own Resource = "*", matching this file's own general
          # "scope as tightly as the API actually allows" convention.
          # PublishFunction included alongside Create/Describe/Update/
          # Delete since this resource sets publish = true, moving it
          # from DEVELOPMENT to LIVE stage -- a distinct action Terraform
          # calls as part of the same apply, not implied by CreateFunction
          # alone.
          Sid    = "ManageCloudFrontFunctions"
          Effect = "Allow"
          Action = [
            "cloudfront:CreateFunction",
            "cloudfront:DescribeFunction",
            "cloudfront:GetFunction",
            "cloudfront:UpdateFunction",
            "cloudfront:PublishFunction",
            "cloudfront:DeleteFunction",
          ]
          Resource = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:function/*"
        },
        {
          Sid    = "ManageCloudFrontInvalidations"
          Effect = "Allow"
          Action = [
            "cloudfront:CreateInvalidation",
            "cloudfront:GetInvalidation",
            "cloudfront:ListInvalidations",
          ]
          Resource = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/*"
        },
        {
          # RequestCertificate has no resource-level support either (the
          # certificate ARN doesn't exist until the call succeeds).
          Sid      = "RequestCertificate"
          Effect   = "Allow"
          Action   = "acm:RequestCertificate"
          Resource = "*"
        },
        {
          Sid    = "ManageCertificate"
          Effect = "Allow"
          Action = [
            "acm:DescribeCertificate",
            "acm:GetCertificate",
            "acm:DeleteCertificate",
            "acm:AddTagsToCertificate",
            "acm:RemoveTagsFromCertificate",
            "acm:ListTagsForCertificate",
          ]
          Resource = "arn:aws:acm:us-east-1:${data.aws_caller_identity.current.account_id}:certificate/*"
        },
        {
          Sid    = "ManageDns"
          Effect = "Allow"
          Action = [
            "route53:ChangeResourceRecordSets",
            "route53:GetHostedZone",
            "route53:ListResourceRecordSets",
            "route53:ListTagsForResource",
          ]
          Resource = "arn:aws:route53:::hostedzone/Z07879811I86VC8PAL8HX"
        },
        {
          Sid      = "ReadDnsChanges"
          Effect   = "Allow"
          Action   = "route53:GetChange"
          Resource = "arn:aws:route53:::change/*"
        },
      ]

      plan_policy_statements = [
        {
          # The AWS provider's core aws_s3_bucket read unconditionally
          # checks this full set of bucket-level settings on every refresh,
          # regardless of which ones this config actually sets -- found live
          # one AccessDenied at a time (GetBucketAcl, then GetBucketCORS)
          # against the narrowly-scoped plan role. Granting the whole
          # standard read set up front avoids further one-at-a-time
          # apply/replan cycles; it's still read-only and scoped to exactly
          # this one bucket ARN.
          #
          # Temporarily also lists the old www.jkandler.de ARN, same
          # reasoning as ManageSiteBucket above: a plan against the bucket
          # rename needs to refresh the still-live old bucket's state to
          # compute an accurate diff. Remove once that apply is done.
          Sid    = "ReadSiteBucket"
          Effect = "Allow"
          Action = [
            "s3:GetAccelerateConfiguration",
            "s3:GetBucketAcl",
            "s3:GetBucketCORS",
            "s3:GetBucketLocation",
            "s3:GetBucketLogging",
            "s3:GetBucketObjectLockConfiguration",
            "s3:GetBucketOwnershipControls",
            "s3:GetBucketPolicy",
            "s3:GetBucketPublicAccessBlock",
            "s3:GetBucketRequestPayment",
            "s3:GetBucketTagging",
            "s3:GetBucketVersioning",
            "s3:GetBucketWebsite",
            "s3:GetEncryptionConfiguration",
            "s3:GetLifecycleConfiguration",
            "s3:GetReplicationConfiguration",
            "s3:ListBucket",
          ]
          Resource = ["arn:aws:s3:::jkandler-website", "arn:aws:s3:::www.jkandler.de"]
        },
        {
          Sid      = "DescribeSharedKmsKeyForSiteBucket"
          Effect   = "Allow"
          Action   = "kms:DescribeKey"
          Resource = data.aws_kms_alias.shared.target_key_arn
        },
        {
          Sid      = "ListKmsAliasesForSiteBucket"
          Effect   = "Allow"
          Action   = "kms:ListAliases"
          Resource = "*"
        },
        {
          Sid    = "ReadCloudFront"
          Effect = "Allow"
          Action = [
            "cloudfront:GetDistribution",
            "cloudfront:ListTagsForResource",
            "cloudfront:GetOriginAccessControl",
          ]
          Resource = "*"
        },
        {
          # Missing from this plan-only role even after apply's own
          # ManageCloudFrontFunctions statement above was added -- that
          # only covers the apply_policy_statements' separate
          # role (website-github-actions), not this one
          # (website-github-plan). `terraform plan` refreshes
          # aws_cloudfront_function.url_rewrite's state via
          # DescribeFunction (metadata) and GetFunction (code/stage),
          # same two read actions the apply role already needed for its
          # own refresh step. Read-only subset of ManageCloudFrontFunctions
          # above, same resource-scoped ARN.
          Sid    = "ReadCloudFrontFunctions"
          Effect = "Allow"
          Action = [
            "cloudfront:DescribeFunction",
            "cloudfront:GetFunction",
          ]
          Resource = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:function/*"
        },
        {
          Sid    = "ReadCertificate"
          Effect = "Allow"
          Action = [
            "acm:DescribeCertificate",
            "acm:ListTagsForCertificate",
          ]
          Resource = "arn:aws:acm:us-east-1:${data.aws_caller_identity.current.account_id}:certificate/*"
        },
        {
          Sid    = "ReadDns"
          Effect = "Allow"
          Action = [
            "route53:GetHostedZone",
            "route53:ListResourceRecordSets",
            "route53:ListTagsForResource",
          ]
          Resource = "arn:aws:route53:::hostedzone/Z07879811I86VC8PAL8HX"
        },
      ]
    }

    aws-budget = {
      state_key = "aws-budget/terraform.tfstate"

      apply_policy_statements = [
        {
          # Budget ARNs don't exist until creation succeeds, same reasoning
          # as RequestCertificate above.
          Sid      = "CreateBudget"
          Effect   = "Allow"
          Action   = "budgets:CreateBudget"
          Resource = "*"
        },
        {
          Sid    = "ManageBudget"
          Effect = "Allow"
          Action = "budgets:*"
          Resource = [
            "arn:aws:budgets::${data.aws_caller_identity.current.account_id}:budget/monthly-cost-alert",
          ]
        },
      ]

      plan_policy_statements = [
        {
          # AWS Budgets' IAM actions don't follow its API operation names:
          # the API call is DescribeBudget, but confirmed live, the IAM
          # action it actually checks is budgets:ViewBudget -- the
          # Describe*-named actions used here before aren't real IAM
          # actions for this service and silently granted nothing.
          Sid      = "ReadBudget"
          Effect   = "Allow"
          Action   = "budgets:ViewBudget"
          Resource = "arn:aws:budgets::${data.aws_caller_identity.current.account_id}:budget/monthly-cost-alert"
        },
        {
          # Confirmed live: the AWS provider always calls
          # ListTagsForResource when reading an aws_budgets_budget, even
          # with no tags configured, to populate tags_all -- a separate
          # IAM action from budgets:ViewBudget.
          Sid      = "ReadBudgetTags"
          Effect   = "Allow"
          Action   = "budgets:ListTagsForResource"
          Resource = "arn:aws:budgets::${data.aws_caller_identity.current.account_id}:budget/monthly-cost-alert"
        },
      ]
    }

    homeserver-health-check = {
      state_key = "homeserver-health-check/terraform.tfstate"

      apply_policy_statements = [
        {
          # Health check IDs are AWS-generated UUIDs, not something
          # Terraform lets you choose in advance the way a budget or
          # CloudWatch alarm name can be -- unlike those, there's no ARN
          # to scope to until after creation, so every health check
          # action here needs Resource "*".
          Sid    = "ManageHealthCheck"
          Effect = "Allow"
          Action = [
            "route53:CreateHealthCheck",
            "route53:GetHealthCheck",
            "route53:UpdateHealthCheck",
            "route53:DeleteHealthCheck",
            "route53:GetHealthCheckStatus",
            "route53:ListTagsForResource",
            "route53:ChangeTagsForResource",
          ]
          Resource = "*"
        },
        {
          Sid    = "ManageAlarm"
          Effect = "Allow"
          Action = [
            "cloudwatch:PutMetricAlarm",
            "cloudwatch:DescribeAlarms",
            "cloudwatch:DeleteAlarms",
            "cloudwatch:TagResource",
            "cloudwatch:UntagResource",
            "cloudwatch:ListTagsForResource",
          ]
          Resource = "arn:aws:cloudwatch:us-east-1:${data.aws_caller_identity.current.account_id}:alarm:homeserver-unreachable"
        },
        {
          # Subscription actions (Get/SetSubscriptionAttributes, Unsubscribe)
          # act on the subscription's own ARN -- the topic ARN plus a
          # ":<subscription-id>" suffix Terraform can't know in advance --
          # not the topic ARN itself, so the resource list covers both.
          Sid    = "ManageSnsTopic"
          Effect = "Allow"
          Action = [
            "sns:CreateTopic",
            "sns:DeleteTopic",
            "sns:GetTopicAttributes",
            "sns:SetTopicAttributes",
            "sns:Subscribe",
            "sns:Unsubscribe",
            "sns:GetSubscriptionAttributes",
            "sns:SetSubscriptionAttributes",
            "sns:ListSubscriptionsByTopic",
            "sns:TagResource",
            "sns:UntagResource",
            "sns:ListTagsForResource",
          ]
          Resource = [
            "arn:aws:sns:us-east-1:${data.aws_caller_identity.current.account_id}:homeserver-health-alerts",
            "arn:aws:sns:us-east-1:${data.aws_caller_identity.current.account_id}:homeserver-health-alerts:*",
          ]
        },
        {
          # Fixes trivy's AWS-0095/AWS-0136 -- this repo's own dedicated
          # CMK for its SNS topic (can't use the shared account-wide key,
          # different region). CreateKey needs Resource "*" -- same
          # reasoning as RequestCertificate above, the key ID doesn't
          # exist until the call succeeds. The rest scoped to a wildcard
          # key/alias ARN in this region, same "ID not known in advance"
          # pattern ManageCertificate below already uses for ACM.
          Sid      = "CreateKmsKey"
          Effect   = "Allow"
          Action   = "kms:CreateKey"
          Resource = "*"
        },
        {
          Sid    = "ManageKmsKey"
          Effect = "Allow"
          Action = [
            "kms:DescribeKey",
            "kms:PutKeyPolicy",
            "kms:GetKeyPolicy",
            "kms:GetKeyRotationStatus",
            "kms:EnableKeyRotation",
            "kms:DisableKeyRotation",
            "kms:TagResource",
            "kms:UntagResource",
            "kms:ListResourceTags",
            "kms:ScheduleKeyDeletion",
            "kms:CreateAlias",
            "kms:DeleteAlias",
            "kms:UpdateAlias",
          ]
          Resource = [
            "arn:aws:kms:us-east-1:${data.aws_caller_identity.current.account_id}:key/*",
            "arn:aws:kms:us-east-1:${data.aws_caller_identity.current.account_id}:alias/homeserver-health-check",
          ]
        },
        {
          # The aws_kms_alias *resource* (not just a data source lookup,
          # like dyndns/website's own gap) also needs this to refresh
          # its own state during plan/apply
          # -- ManageKmsKey's CreateAlias/DeleteAlias/UpdateAlias above
          # weren't enough on their own. No resource-level scoping
          # possible for this action.
          Sid      = "ListKmsAliases"
          Effect   = "Allow"
          Action   = "kms:ListAliases"
          Resource = "*"
        },
      ]

      plan_policy_statements = [
        {
          Sid    = "ReadHealthCheck"
          Effect = "Allow"
          Action = [
            "route53:GetHealthCheck",
            "route53:GetHealthCheckStatus",
            "route53:ListTagsForResource",
          ]
          Resource = "*"
        },
        {
          Sid    = "ReadAlarm"
          Effect = "Allow"
          Action = [
            "cloudwatch:DescribeAlarms",
            "cloudwatch:ListTagsForResource",
          ]
          Resource = "arn:aws:cloudwatch:us-east-1:${data.aws_caller_identity.current.account_id}:alarm:homeserver-unreachable"
        },
        {
          Sid    = "ReadSnsTopic"
          Effect = "Allow"
          Action = [
            "sns:GetTopicAttributes",
            "sns:GetSubscriptionAttributes",
            "sns:ListSubscriptionsByTopic",
            "sns:ListTagsForResource",
          ]
          Resource = [
            "arn:aws:sns:us-east-1:${data.aws_caller_identity.current.account_id}:homeserver-health-alerts",
            "arn:aws:sns:us-east-1:${data.aws_caller_identity.current.account_id}:homeserver-health-alerts:*",
          ]
        },
        {
          Sid    = "ReadKmsKey"
          Effect = "Allow"
          Action = [
            "kms:DescribeKey",
            "kms:GetKeyPolicy",
            "kms:GetKeyRotationStatus",
            "kms:ListResourceTags",
          ]
          Resource = [
            "arn:aws:kms:us-east-1:${data.aws_caller_identity.current.account_id}:key/*",
            "arn:aws:kms:us-east-1:${data.aws_caller_identity.current.account_id}:alias/homeserver-health-check",
          ]
        },
        {
          Sid      = "ListKmsAliases"
          Effect   = "Allow"
          Action   = "kms:ListAliases"
          Resource = "*"
        },
      ]
    }

    ses-relay = {
      state_key = "ses-relay/terraform.tfstate"

      apply_policy_statements = [
        {
          # SES v1's identity-lifecycle actions -- create/verify
          # (VerifyDomainIdentity/VerifyEmailIdentity/VerifyDomainDkim),
          # attribute reads (GetIdentityVerificationAttributes/
          # GetIdentityDkimAttributes, which the AWS provider also calls
          # right after every create, as part of its own Create-then-Read
          # cycle), and delete (DeleteIdentity) -- confirmed live, three
          # separate times, that AWS silently denies every one of these
          # under an identity-ARN-scoped statement regardless of the ARN
          # being correct. SES v1 just doesn't support resource-level
          # permissions for this group; scoping tighter than Resource "*"
          # isn't possible for these specific actions.
          Sid    = "ManageSesIdentities"
          Effect = "Allow"
          Action = [
            "ses:VerifyDomainIdentity",
            "ses:VerifyEmailIdentity",
            "ses:VerifyDomainDkim",
            "ses:GetIdentityVerificationAttributes",
            "ses:GetIdentityDkimAttributes",
            "ses:DeleteIdentity",
          ]
          Resource = "*"
        },
        {
          Sid    = "ManageRoute53Records"
          Effect = "Allow"
          Action = [
            "route53:ChangeResourceRecordSets",
            "route53:GetHostedZone",
            "route53:ListResourceRecordSets",
            "route53:ListTagsForResource",
          ]
          Resource = "arn:aws:route53:::hostedzone/Z07879811I86VC8PAL8HX"
        },
        {
          Sid      = "ReadRoute53Change"
          Effect   = "Allow"
          Action   = "route53:GetChange"
          Resource = "arn:aws:route53:::change/*"
        },
        {
          # Scoped to exactly the one dedicated user this deployment
          # creates -- never a bare "*", so this role can manage that
          # user's own access key but no other IAM principal.
          Sid    = "ManageSmtpUser"
          Effect = "Allow"
          Action = [
            "iam:CreateUser",
            "iam:GetUser",
            "iam:DeleteUser",
            "iam:TagUser",
            "iam:UntagUser",
            "iam:ListUserTags",
            "iam:PutUserPolicy",
            "iam:GetUserPolicy",
            "iam:DeleteUserPolicy",
            "iam:ListUserPolicies",
            "iam:CreateAccessKey",
            "iam:ListAccessKeys",
            "iam:DeleteAccessKey",
          ]
          Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/ses-relay-smtp"
        },
        {
          # Fixes trivy's AWS-0143 (policy attached directly to a user)
          # -- ses-relay-smtp's inline policy moves onto a new group with
          # that user as its only member. Same shape as dyndns's own
          # ManageAcmeDns01Group grant.
          Sid    = "ManageSmtpGroup"
          Effect = "Allow"
          Action = [
            "iam:CreateGroup",
            "iam:DeleteGroup",
            "iam:GetGroup",
            "iam:PutGroupPolicy",
            "iam:GetGroupPolicy",
            "iam:DeleteGroupPolicy",
            "iam:ListGroupPolicies",
            "iam:AddUserToGroup",
            "iam:RemoveUserFromGroup",
          ]
          Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:group/ses-relay-smtp"
        },
      ]

      plan_policy_statements = [
        {
          # Same Resource "*" requirement as the apply role's
          # VerifyAndReadSesIdentities statement -- these batch-style Get
          # calls run during plan's own state refresh once the identities
          # exist, and don't support identity-ARN scoping.
          Sid    = "ReadSesIdentities"
          Effect = "Allow"
          Action = [
            "ses:GetIdentityVerificationAttributes",
            "ses:GetIdentityDkimAttributes",
          ]
          Resource = "*"
        },
        {
          Sid    = "ReadRoute53Records"
          Effect = "Allow"
          Action = [
            "route53:GetHostedZone",
            "route53:ListResourceRecordSets",
            "route53:ListTagsForResource",
          ]
          Resource = "arn:aws:route53:::hostedzone/Z07879811I86VC8PAL8HX"
        },
        {
          Sid    = "ReadSmtpUser"
          Effect = "Allow"
          Action = [
            "iam:GetUser",
            "iam:ListUserTags",
            "iam:GetUserPolicy",
            "iam:ListUserPolicies",
            "iam:ListAccessKeys",
          ]
          Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/ses-relay-smtp"
        },
        {
          Sid    = "ReadSmtpGroup"
          Effect = "Allow"
          Action = [
            "iam:GetGroup",
            "iam:GetGroupPolicy",
            "iam:ListGroupPolicies",
          ]
          Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:group/ses-relay-smtp"
        },
      ]
    }

    secrets-manager = {
      state_key = "secrets-manager/terraform.tfstate"
      apply_policy_statements = concat(
        local.secrets_manager_statements,
        local.secrets_manager_rotation_check_statement,
      )
      plan_policy_statements = local.secrets_manager_statements
    }
  }
}
