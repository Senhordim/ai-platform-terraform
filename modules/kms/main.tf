# Uma CMK por domínio (logs, dados, knowledge base), com rotação automática e
# key policy explícita. Em key policies, "Resource": "*" significa "esta
# chave" (exigência do KMS) — não é um curinga sobre outras chaves.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  root_arn   = "arn:${local.partition}:iam::${local.account_id}:root"

  # Ações de administração (sem uso criptográfico) concedidas à conta e aos
  # papéis de administração de chaves.
  admin_actions = [
    "kms:CancelKeyDeletion",
    "kms:CreateAlias",
    "kms:CreateGrant",
    "kms:DeleteAlias",
    "kms:DescribeKey",
    "kms:DisableKey",
    "kms:DisableKeyRotation",
    "kms:EnableKey",
    "kms:EnableKeyRotation",
    "kms:GetKeyPolicy",
    "kms:GetKeyRotationStatus",
    "kms:ListAliases",
    "kms:ListGrants",
    "kms:ListKeyPolicies",
    "kms:ListResourceTags",
    "kms:PutKeyPolicy",
    "kms:RevokeGrant",
    "kms:ScheduleKeyDeletion",
    "kms:TagResource",
    "kms:UntagResource",
    "kms:UpdateAlias",
    "kms:UpdateKeyDescription",
  ]

  usage_actions = [
    "kms:Decrypt",
    "kms:DescribeKey",
    "kms:Encrypt",
    "kms:GenerateDataKey",
    "kms:GenerateDataKeyWithoutPlaintext",
    "kms:ReEncryptFrom",
    "kms:ReEncryptTo",
  ]

  domains = {
    logs = {
      description = "CMK de logs: CloudWatch Logs, CloudTrail, invocation logging, VPC Flow Logs"
    }
    data = {
      description = "CMK de dados: buckets de dados, golden sets, AgentCore, ECR, CUR"
    }
    kb = {
      description = "CMK da knowledge base: bucket de documentos, OpenSearch Serverless, Bedrock KB"
    }
  }
}

# ---------------------------------------------------------------- logs ----
data "aws_iam_policy_document" "logs" {
  #checkov:skip=CKV_AWS_109:Key policy — Resource "*" refere-se apenas a esta chave.
  #checkov:skip=CKV_AWS_111:Key policy — Resource "*" refere-se apenas a esta chave.
  #checkov:skip=CKV_AWS_356:Key policy — Resource "*" refere-se apenas a esta chave.
  statement {
    sid       = "AccountAdministration"
    actions   = local.admin_actions
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = concat([local.root_arn], var.key_admin_role_arns)
    }
  }

  statement {
    sid       = "AccountUsageViaIam"
    actions   = local.usage_actions
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.root_arn]
    }
  }

  statement {
    sid = "CloudWatchLogs"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"]
    }
  }

  statement {
    sid       = "CloudTrailEncrypt"
    actions   = ["kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:${local.partition}:cloudtrail:*:${local.account_id}:trail/*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "ServiceLogDelivery"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type = "Service"
      identifiers = [
        "bedrock.amazonaws.com",
        "delivery.logs.amazonaws.com",
        "config.amazonaws.com",
        "firehose.amazonaws.com",
      ]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

# ---------------------------------------------------------------- data ----
data "aws_iam_policy_document" "data" {
  #checkov:skip=CKV_AWS_109:Key policy — Resource "*" refere-se apenas a esta chave.
  #checkov:skip=CKV_AWS_111:Key policy — Resource "*" refere-se apenas a esta chave.
  #checkov:skip=CKV_AWS_356:Key policy — Resource "*" refere-se apenas a esta chave.
  statement {
    sid       = "AccountAdministration"
    actions   = local.admin_actions
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = concat([local.root_arn], var.key_admin_role_arns)
    }
  }

  statement {
    sid       = "AccountUsageViaIam"
    actions   = local.usage_actions
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.root_arn]
    }
  }

  statement {
    sid       = "AwsServicesInThisAccount"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt", "kms:DescribeKey", "kms:CreateGrant"]
    resources = ["*"]
    principals {
      type = "Service"
      identifiers = [
        "bedrock.amazonaws.com",
        "bedrock-agentcore.amazonaws.com",
        "bcm-data-exports.amazonaws.com",
        "billingreports.amazonaws.com",
      ]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

# ------------------------------------------------------------------ kb ----
data "aws_iam_policy_document" "kb" {
  #checkov:skip=CKV_AWS_109:Key policy — Resource "*" refere-se apenas a esta chave.
  #checkov:skip=CKV_AWS_111:Key policy — Resource "*" refere-se apenas a esta chave.
  #checkov:skip=CKV_AWS_356:Key policy — Resource "*" refere-se apenas a esta chave.
  statement {
    sid       = "AccountAdministration"
    actions   = local.admin_actions
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = concat([local.root_arn], var.key_admin_role_arns)
    }
  }

  statement {
    sid       = "AccountUsageViaIam"
    actions   = local.usage_actions
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.root_arn]
    }
  }

  statement {
    sid       = "AossAndBedrockViaService"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.root_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values = [
        "aoss.${local.region}.amazonaws.com",
        "bedrock.${local.region}.amazonaws.com",
        "s3.${local.region}.amazonaws.com",
      ]
    }
  }

  # Macie precisa decifrar objetos para classificar o bucket de documentos.
  # Usa aws:PrincipalArn (e não o principal direto) porque a service-linked
  # role só passa a existir depois que o Macie é habilitado.
  statement {
    sid       = "MacieClassification"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.root_arn]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/macie.amazonaws.com/AWSServiceRoleForAmazonMacie"]
    }
  }
}

locals {
  policies = {
    logs = data.aws_iam_policy_document.logs.json
    data = data.aws_iam_policy_document.data.json
    kb   = data.aws_iam_policy_document.kb.json
  }
}

resource "aws_kms_key" "this" {
  for_each = local.domains

  description             = "${var.name_prefix} — ${each.value.description}"
  enable_key_rotation     = true
  rotation_period_in_days = var.rotation_period_in_days
  deletion_window_in_days = var.deletion_window_in_days
  policy                  = local.policies[each.key]

  tags = { kms_domain = each.key }
}

resource "aws_kms_alias" "this" {
  for_each = local.domains

  name          = "alias/${var.name_prefix}-${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}
