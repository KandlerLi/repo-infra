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

  aws_policies = {
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
          Sid    = "ReadBudget"
          Effect = "Allow"
          Action = [
            "budgets:DescribeBudget",
            "budgets:DescribeBudgets",
            "budgets:DescribeNotificationsForBudget",
            "budgets:DescribeSubscribersForNotification",
          ]
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
  }
}
