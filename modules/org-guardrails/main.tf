# SCPs da plataforma de agentes — aplicadas na conta de GERENCIAMENTO da
# AWS Organizations (stack separado: stacks/org-guardrails).
# Agrupadas em 2 policies para respeitar o limite de 5 SCPs por alvo.
#
# Em SCPs de negação, curingas de serviço (ex.: "bedrock:*") são
# intencionais: negam qualquer ação, inclusive as que a AWS criar no futuro.

data "aws_partition" "current" {}

locals {
  partition = data.aws_partition.current.partition

  allowed_model_arns = [
    for m in var.allowed_model_ids : "arn:${local.partition}:bedrock:${var.allowed_region}::foundation-model/${m}"
  ]
}

data "aws_iam_policy_document" "ai_region_and_models" {
  #checkov:skip=CKV_AWS_356:SCP de negação — Resource "*" é o escopo correto.
  #checkov:skip=CKV_AWS_111:SCP de negação, não concede permissões.
  #checkov:skip=CKV_AWS_109:SCP de negação, não concede permissões.

  # 1) Bedrock e AgentCore só em sa-east-1.
  statement {
    sid    = "DenyBedrockOutsideAllowedRegion"
    effect = "Deny"
    actions = [
      "bedrock:*",
      "bedrock-agentcore:*",
    ]
    resources = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = [var.allowed_region]
    }
    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = var.exempt_principal_arns
    }
  }

  # 2) Invocação só de modelos da allowlist (direto ou via application
  #    inference profile da conta). Perfis cross-region (us./global.) ficam
  #    de fora e são negados.
  statement {
    sid    = "DenyModelsOutsideAllowlist"
    effect = "Deny"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:CreateModelInvocationJob",
    ]
    not_resources = concat(
      local.allowed_model_arns,
      ["arn:${local.partition}:bedrock:${var.allowed_region}:*:application-inference-profile/*"],
    )
  }
}

data "aws_iam_policy_document" "ai_logging_and_identity" {
  #checkov:skip=CKV_AWS_356:SCP de negação — Resource "*" é o escopo correto.
  #checkov:skip=CKV_AWS_111:SCP de negação, não concede permissões.
  #checkov:skip=CKV_AWS_109:SCP de negação, não concede permissões.

  # 3) Não desligar CloudTrail nem o model invocation logging.
  statement {
    sid    = "ProtectAuditLogging"
    effect = "Deny"
    actions = [
      "cloudtrail:DeleteTrail",
      "cloudtrail:PutEventSelectors",
      "cloudtrail:StopLogging",
      "cloudtrail:UpdateTrail",
      "bedrock:DeleteModelInvocationLoggingConfiguration",
      "bedrock:PutModelInvocationLoggingConfiguration",
    ]
    resources = ["*"]
    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = var.logging_admin_principal_arns
    }
  }

  # 4) Sem usuários IAM e sem access keys.
  statement {
    sid    = "DenyIamUsersAndAccessKeys"
    effect = "Deny"
    actions = [
      "iam:CreateAccessKey",
      "iam:CreateLoginProfile",
      "iam:CreateUser",
    ]
    resources = ["*"]
  }
}

resource "aws_organizations_policy" "ai_region_and_models" {
  name        = "${var.name_prefix}-ai-region-and-models"
  description = "Bedrock/AgentCore só em ${var.allowed_region}; invocação só de modelos da allowlist."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.ai_region_and_models.minified_json
}

resource "aws_organizations_policy" "ai_logging_and_identity" {
  name        = "${var.name_prefix}-ai-logging-and-identity"
  description = "Protege CloudTrail e invocation logging; proíbe usuários IAM e access keys."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.ai_logging_and_identity.minified_json
}

resource "aws_organizations_policy_attachment" "ai_region_and_models" {
  for_each  = toset(var.target_ids)
  policy_id = aws_organizations_policy.ai_region_and_models.id
  target_id = each.value
}

resource "aws_organizations_policy_attachment" "ai_logging_and_identity" {
  for_each  = toset(var.target_ids)
  policy_id = aws_organizations_policy.ai_logging_and_identity.id
  target_id = each.value
}
