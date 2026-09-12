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

locals {
  aws_region = "eu-central-1"

  # k3s-apps' own read access to the Secrets Manager groups its
  # Terraform reads directly (data "aws_secretsmanager_secret_version",
  # k3s-apps' own secrets.tf) -- the SOPS-to-Secrets-Manager cutover,
  # PARKED.md's own writeup. Deliberately identical for apply AND plan:
  # unlike dyndns's own ManageDynDnsSecret/ReadDynDnsSecretMetadata
  # split (where the plan role never needs the real value, since that
  # secret is Lambda-runtime-only), these values flow directly into
  # Terraform's own jsondecode() locals, so even a plan needs
  # GetSecretValue to compute a diff, not just DescribeSecret. ARNs are
  # hand-built with a trailing "-*" wildcard for the random suffix
  # Secrets Manager appends, matching dyndns's own established
  # convention -- these are a different repo's own resources
  # (bootstrap/secrets-manager, or still bootstrap/terraform-state for
  # any group not yet migrated -- see that repo's own README for the
  # migration-status table), so there's no real Terraform resource
  # reference to use here the way that repo's own operator.tf could.
  # k3s-apps/ghcr-pull-token is a genuinely new secret (split out of
  # home-infra/home-agent 2026-09-12), not a migration, but reads the
  # same way. Excludes home-infra/nextcloud (Ansible-only,
  # infra/home-infra never touches this repo) and
  # home-infra/github-runner (bootstrap/k3s-bootstrap's own, not
  # k3s-apps').
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
          Sid    = "ManageSiteBucket"
          Effect = "Allow"
          Action = "s3:*"
          Resource = [
            "arn:aws:s3:::www.jkandler.de",
            "arn:aws:s3:::www.jkandler.de/*",
          ]
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
          Resource = "arn:aws:s3:::www.jkandler.de"
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
      ]
    }
  }
}
