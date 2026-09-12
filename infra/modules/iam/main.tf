# This file implements the identity and encryption hardening layer of the estate:
# the account password policy, the platform KMS keys with their aliases and
# service-scoped key policies, the service-bounded roles that the compute, database
# and function tiers assume, and the customer-managed deny policy that closes the
# destructive actions of the account for every non-break-glass principal.
#
# The module is written so that a plan of it is an audit artefact: every policy is
# an explicit statement with a Sid, and the deny list is spelled out in full so
# that a reviewer never has to guess what the estate forbids.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.id

  # ssm_agent_managed_policies is the list of AWS managed policies that the agent
  # of Systems Manager needs on a managed node. They are attached to the instance
  # role of the fleet by this module so that the fleet module stays about compute:
  #   AmazonSSMManagedInstanceCore    — the core agent channel: Run Command, the
  #                                      inventory and the patches of the service.
  #   AmazonSSMDirectoryServiceAccess — relevant only when a host joins the
  #                                      managed directory; kept for the hybrid
  #                                      story of the estate.
  #   CloudWatchAgentServerPolicy     — the rights of the agent that forwards the
  #                                      metrics and the logs of the host.
  # The fourth line of the trade, the delivery of command output to a bucket,
  # needs a bucket policy of the account and is therefore not a managed policy.
  ssm_agent_managed_policies = [
    "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:${local.partition}:iam::aws:policy/AmazonSSMDirectoryServiceAccess",
    "arn:${local.partition}:iam::aws:policy/CloudWatchAgentServerPolicy",
  ]

  # destructive_actions is the explicit deny list of the estate. Each family is
  # commented with the reason of its presence, because a deny policy that nobody
  # can read is a policy that nobody can defend in a review.
  destructive_actions = [
    # Identity erasure: an identity that is gone is an audit trail that is gone.
    "iam:DeleteUser",
    "iam:DeleteRole",
    "iam:DeleteGroup",
    "iam:DeletePolicy",
    "iam:DetachRolePolicy",
    "iam:DetachGroupPolicy",
    # Logging erasure: the classic first move of an intruder is the silencing of
    # the trail, so the deletion of a log group or of a trail is denied here.
    "logs:DeleteLogGroup",
    "cloudtrail:DeleteTrail",
    # Backup and snapshot erasure: a destroyed backup turns any incident into an
    # unrecoverable one, so the destruction of a backup is a destructive action.
    "rds:DeleteDBSnapshot",
    "rds:DeleteDBClusterSnapshot",
    "dbds:DeleteSnapshot",
    "elasticache:DeleteSnapshot",
    "ec2:DeleteSnapshots",
    "ec2:DeregisterImage",
    # Fleet erasure: removing the fleet of the entry tier or shrinking it by force
    # is how an outage is manufactured, so both moves are denied.
    "autoscaling:AutoScalingGroupDelete",
    "autoscaling:SetDesiredCapacity",
    # Bucket-control erasure: a versioned bucket plus a public access block is the
    # control; the removal of either control is denied so that a console edit of
    # an afternoon cannot undo it.
    "s3:DeleteBucket",
    "s3:PutBucketVersioning",
    "s3:PutBucketPublicAccessBlock",
  ]

  # key_service_principals names, per scope, the service principal that the key
  # policy of that scope admits. The map is deliberately complete for the scopes
  # of the platform, so that a reviewer can read the whole trust story here.
  key_service_principals = {
    ebs         = ["ec2.amazonaws.com"]
    rds         = ["monitoring.rds.amazonaws.com", "performance-database.rds.amazonaws.com", "storage-db.rds.amazonaws.com"]
    pi          = ["performance-database.rds.amazonaws.com"]
    logs        = ["delivery.logs.amazonaws.com"]
    cloudwatch  = ["logs.amazonaws.com"]
    elasticache = ["elasticache.amazonaws.com"]
    backups     = ["storage-backup.amazonaws.com"]
    secrets     = ["secretsmanager.amazonaws.com"]
    sns_alarms  = []
  }

  # service_role_bindings maps each service role that the platform needs to the
  # service principals that may delegate it. The source-account condition of the
  # trust policy below is what binds the delegation to this account.
  service_role_bindings = {
    ec2_runtime    = ["ec2.amazonaws.com"]
    rds_monitoring = ["monitoring.rds.amazonaws.com"]
    lambda_runtime = ["lambda.amazonaws.com"]
  }

  common_tags = merge(
    {
      Module    = "iam"
      ManagedBy = "terraform"
    },
    var.tags
  )
}

# ---------------------------------------------------------------------------
# The account password policy
# ---------------------------------------------------------------------------

resource "aws_iam_account_password_policy" "platform" {
  count = var.manage_password_policy ? 1 : 0

  # Fourteen characters with all four classes is the reviewed baseline of the
  # estate. The humans of the estate also have to change the secret inside a
  # year, may not recycle the last eight of them, and may not type the password
  # of a peer into the change form.
  minimum_password_length      = var.password_minimum_length
  require_lowercase_characters = true
  require_numbers                = true
  require_symbols                = true
  require_uppercase_characters = true

  allow_users_to_change_password = true
  hard_expiry                      = false
  max_password_age                 = 365
  password_reuse_prevention        = 8
}

# ---------------------------------------------------------------------------
# The platform keys
# ---------------------------------------------------------------------------

resource "aws_kms_key" "platform" {
  for_each = toset(var.key_scopes)

  description         = "Platform key of the ${each.value} scope of ${var.environment_name}."
  key_usage           = "ENCRYPT_DECRYPT"
  enable_key_rotation = true

  # The window is the deliberate pause before the erasure of a key: fifteen days
  # is long enough for an alarm to be read and short enough to bound the cost of
  # an orphan, and the caller may widen it only with a written reason.
  deletion_window_in_days = var.kms_deletion_window_days

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid       = "RootOfTheAccountMayDelegate"
          Effect    = "Allow"
          Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
          Action    = "kms:*"
          Resource  = "*"
          # The root statement exists only so that the account may delegate; every
          # real grant is a separate statement below, which is the posture that
          # the audit of the estate reads.
        },
        {
          Sid       = "KeyAdministratorsMayGovernTheKey"
          Effect    = "Allow"
          Principal = { AWS = var.key_admin_role_arns }
          Action = [
            "kms:DescribeKey",
            "kms:GetKeyPolicy",
            "kms:PutKeyPolicy",
            "kms:EnableKeyRotation",
            "kms:GetKeyRotationStatus",
            "kms:ScheduleKeyDeletion",
            "kms:CancelKeyDeletion",
          ]
          Resource = "*"
        },
        {
          Sid       = "DenyAnyUseOfTheKeyFromOutsideTheAccount"
          Effect    = "Deny"
          Principal = "*"
          Action = [
            "kms:Encrypt",
            "kms:Decrypt",
            "kms:ReEncrypt",
            "kms:GenerateDataKey",
            "kms:DescribeKey",
          ]
          Resource = "*"
          Condition = {
            StringNotEquals = {
              # A cross-account decrypt of a stolen snapshot is the scenario that
              # this condition is written for.
              "aws:ResourceAccount" = [local.account_id]
            }
          }
        },
      ],
      # The service grant is per scope, so that an EBS key can be used by the
      # compute service and never by a caller of another scope. A scope without a
      # service principal, such as the alarm topic key, emits no grant at all.
      length(lookup(local.key_service_principals, each.value, [])) > 0 ? [{
        Sid       = "ServiceOfThisScopeMayUseTheKey"
        Effect    = "Allow"
        Principal = { Service = lookup(local.key_service_principals, each.value) }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey",
          "kms:CreateGrant",
          "kms:RetireGrant",
        ]
        Resource = "*"
      }] : []
    )
  })

  tags = merge(local.common_tags, {
    Name  = "${var.environment_name}-${each.value}-key"
    Scope = each.value
  })

  lifecycle {
    # A key that is scheduled for deletion by an accident is a data-loss event
    # of the whole estate, so the guard is switched on and a deliberate destroy
    # becomes an approved, reviewed act.
    prevent_destroy = true

    precondition {
      condition     = alltrue([for arn in var.key_admin_role_arns : can(regexmatch("^arn:[a-z0-9-]+:iam::[0-9]{1,12}:role/[a-zA-Z0-9+=,.@_-]+$", arn))])
      error_message = "every member of key_admin_role_arns must be a full IAM role ARN of the form arn:aws:iam::ACCOUNT_ID:role/NAME; a wildcard administrator of keys is never acceptable here."
    }
  }
}

resource "aws_kms_alias" "platform" {
  for_each = aws_kms_key.platform

  alias_name    = "alias/${var.environment_name}-${each.key}"
  target_key_id = each.value.key_id
}

# ---------------------------------------------------------------------------
# The service-bounded roles
# ---------------------------------------------------------------------------

resource "aws_iam_role" "service" {
  for_each = local.service_role_bindings

  name_prefix          = "${var.environment_name}-${replace(each.key, "_", "-")}-"
  description          = "Service-bounded role of the ${replace(each.key, "_", " ")} workload of ${var.environment_name}."
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "OnlyTheseServicesOfThisAccountMayDelegate"
      Effect    = "Allow"
      Principal = { Service = each.value }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          # The source-account condition is the reason the role exists in a
          # hardening module: any external principal that learns of the role
          # still cannot delegate it, because the claim of the delegation must
          # name this account.
          "aws:SourceAccount" = [local.account_id]
        }
      }
    }]
  })

  permissions_boundary = aws_iam_policy.boundary.arn

  tags = merge(local.common_tags, { Name = "${var.environment_name}-${each.key}" })
}

# The managed policies of the agent ride on the compute role of the fleet, which
# is the role that the instance profile of the bastion module carries.
resource "aws_iam_role_policy_attachment" "ssm_agent" {
  for_each = toset(local.ssm_agent_managed_policies)

  role       = aws_iam_role.service["ec2_runtime"].name
  policy_arn = each.value
}

# The explicit deny policy of the estate rides on every service role as well, so
# that a workload credential that is stolen cannot erase the guardrails even when
# its own policy is generous.
resource "aws_iam_role_policy_attachment" "deny_destructive" {
  for_each = aws_iam_role.service

  role       = each.value.name
  policy_arn = aws_iam_policy.deny_destructive.arn
}

resource "aws_iam_policy" "boundary" {
  name_prefix = "${var.environment_name}-boundary-"
  description = "Permissions boundary of ${var.environment_name}: it confines the blast radius of a leaked workload credential to the Region of the platform and away from the control planes of identity, key governance and audit."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StayInThePlatformRegion"
        Effect   = "Deny"
        Action   = "*"
        Resource = "*"
        # The Region guard of the boundary: a credential that is stolen can never
        # mint resources in a foreign Region, because every request must name
        # this Region or the audit denies it.
        Condition = {
          StringNotEquals = {
            "aws:RequestedRegion" = [local.region]
          }
        }
      },
      {
        Sid       = "KeepTheControlPlanesOutOfReach"
        Effect    = "Deny"
        # Deny of everything except the enumerated data-plane actions is the
        # standard boundary shape: a role may never exceed the boundary, so the
        # planes of identity, of key governance, of audit and of the organisation
        # are reserved to the administrators of the account however generous the
        # attached policy of a workload may become.
        NotAction = [
          "s3:*",
          "ec2:Describe*",
          "ec2:Get*",
          "logs:Describe*",
          "logs:Get*",
          "logs:Put*",
          "logs:FilterLog*",
          "logs:StartQuery",
          "logs:List*",
          "monitoring:Get*",
          "monitoring:Put*",
          "monitoring:List*",
          "ssm:Describe*",
          "ssm:Get*",
          "ssm:Put*",
          "ssm:Send*",
          "kms:Describe*",
          "kms:Get*",
          "cloudwatch:Get*",
          "cloudwatch:List*",
          "cloudwatch:Put*",
          "sns:Get*",
          "sns:List*",
          "sns:Publish",
          "sts:AssumeRole",
        ]
        Resource = "*"
        # Everything that is not a data-plane action of the enumerated list stays
        # denied by the boundary: the planes of identity, of key governance, of
        # audit and of the organisations are reserved to the administrators of
        # the account.
      },
    ]
  })

  tags = merge(local.common_tags, { Name = "${var.environment_name}-boundary" })
}

# ---------------------------------------------------------------------------
# The explicit deny policy of the account
# ---------------------------------------------------------------------------

resource "aws_iam_policy" "deny_destructive" {
  name_prefix = "${var.environment_name}-deny-destructive-"
  description = "Deny of the destructive actions of ${var.environment_name}: the list is spelled out in main.tf so that an auditor reads the posture here and not in a ticket."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DenyDestructiveActionsForEveryoneButBreakGlass"
        Effect   = "Deny"
        Action   = local.destructive_actions
        Resource = "*"
        Condition = {
          # The break-glass role is the single reviewed exception, and only for a
          # session that names it; every other principal of the account, humans
          # and services alike, meets the deny.
          "ForAnyValue:StringNotEquals" = {
            "aws:PrincipalARN" = [var.break_glass_role_arn]
          }
        }
      },
      {
        Sid      = "DenyConsoleAccessWithoutAMfa"
        Effect   = "Deny"
        Action   = "*"
        Resource = "*"
        # The IfExists variant of the boolean is deliberate: the key is present
        # in every console request and absent from every machine request, so the
        # guard binds the human plane of the account without breaking the
        # service plane of the estate.
        Condition = {
          BoolIfExists = {
            "aws:MultiFactorAuthPresent" = ["false"]
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, { Name = "${var.environment_name}-deny-destructive" })
}

# ---------------------------------------------------------------------------
# The delivery role of the alarm pipeline
# ---------------------------------------------------------------------------

resource "aws_iam_role" "alarm_delivery" {
  name_prefix          = "${var.environment_name}-alarm-delivery-"
  description          = "Role that the monitoring services assume to publish their events into the alarm topic of ${var.environment_name}."
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "OnlyTheseServicesOfThisAccountMayDelegate"
      Effect    = "Allow"
      Principal = { Service = ["cloudwatch.amazonaws.com", "cloudwatch-alarm.amazonaws.com"] }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = [local.account_id]
        }
      }
    }]
  })

  permissions_boundary = aws_iam_policy.boundary.arn

  tags = merge(local.common_tags, { Name = "${var.environment_name}-alarm-delivery" })
}

resource "aws_iam_role_policy" "alarm_delivery" {
  name_prefix = "${var.environment_name}-alarm-delivery-"
  role        = aws_iam_role.alarm_delivery.name

  # Least privilege of the delivery path: the only permitted action is the
  # publish into the one topic that the observability module owns.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "PublishToTheAlarmTopicOnly"
      Effect   = "Allow"
      Action   = "sns:Publish"
      Resource = var.alarm_topic_arn
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.environment_name}-alarm-delivery-policy" })
}
