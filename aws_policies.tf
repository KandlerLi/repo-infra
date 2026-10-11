# Per-repo AWS deploy permissions beyond modules/repo's state baseline: see README, "IAM policy notes".

# Resolved here so the real key ARN lands in each policy, self-updating if the key is recreated.
data "aws_kms_alias" "shared" {
  name = "alias/shared"
}

locals {
  aws_region = "eu-central-1"

  # Same for plan and apply: the values flow into k3s-apps' Terraform, so a plan needs GetSecretValue too.
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
        "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:k3s-apps/bulwark-*",
        "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:k3s-apps/stalwart-*",
        "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:k3s-apps/paperless-*",
      ]
    },
  ]

  # Apply-only, in its own statement: a leaked token can write exactly this one secret.
  k3s_apps_blocky_rotation_statement = [
    {
      Sid      = "RotateBlockyPostgresPassword"
      Effect   = "Allow"
      Action   = "secretsmanager:PutSecretValue"
      Resource = "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:home-infra/blocky-*"
    },
  ]

  # Empty containers only, never values. GetResourcePolicy and UpdateSecret: see README.
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

  # identity/* because SES also checks the external recipient's identity: see README.
  secrets_manager_rotation_check_statement = [
    {
      Sid      = "SendRotationReminderEmail"
      Effect   = "Allow"
      Action   = "ses:SendEmail"
      Resource = "arn:aws:ses:${local.aws_region}:${data.aws_caller_identity.current.account_id}:identity/*"
    },
  ]

  aws_policies = {
    # No AWS resources of its own: state access, secret reads and the apply-only blocky rotation write.
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

      # The Lambda runtime role, which the deploy role has to introspect.
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
            # Needed to set kms_key_id on an existing log group: see README.
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
          # This one user only, never "*".
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
          # Group for trivy AWS-0143; Add/RemoveUserFromGroup need permission on the group only.
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
          # DescribeKey to reference the shared key; ListAliases has no resource-level scoping.
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
          # Bucket lifecycle and the deploy's s3 sync. The jkandler-website ARNs are leftovers: see README.
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
          # s3 sync's PutObject needs GenerateDataKey now that the bucket uses the shared key.
          Sid      = "UseSharedKmsKeyForSiteBucket"
          Effect   = "Allow"
          Action   = ["kms:GenerateDataKey*", "kms:Decrypt", "kms:DescribeKey"]
          Resource = data.aws_kms_alias.shared.target_key_arn
        },
        {
          # For website's alias/shared lookup; ListAliases has no resource-level scoping.
          Sid      = "ListKmsAliasesForSiteBucket"
          Effect   = "Allow"
          Action   = "kms:ListAliases"
          Resource = "*"
        },
        {
          # CloudFront has no resource-level scoping for distributions and OAC.
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
          # Functions do take resource ARNs, unlike distributions; publish = true needs PublishFunction.
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
          # The certificate ARN only exists after the call succeeds.
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
          # The provider's bucket read checks every bucket-level setting on refresh: see README.
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
          # The plan role refreshes the function via DescribeFunction and GetFunction.
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
          # Budget ARNs only exist after creation.
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
          # The IAM action behind DescribeBudget is budgets:ViewBudget.
          Sid      = "ReadBudget"
          Effect   = "Allow"
          Action   = "budgets:ViewBudget"
          Resource = "arn:aws:budgets::${data.aws_caller_identity.current.account_id}:budget/monthly-cost-alert"
        },
        {
          # The provider always reads tags_all, even with no tags set.
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
          # Health check IDs are AWS-generated, so there is no ARN to scope to.
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
          # Subscription actions act on the subscription ARN, not the topic ARN.
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
          # Own CMK for the SNS topic (other region, trivy AWS-0095/0136); CreateKey needs "*".
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
          # The aws_kms_alias resource needs this on refresh; no resource-level scoping.
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
          # SES v1 identity actions take no resource-level scoping: see README.
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
          # This one user only, never "*".
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
          # Group for trivy AWS-0143, same shape as dyndns' ManageAcmeDns01Group.
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
          # Same Resource "*" requirement as ManageSesIdentities.
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
