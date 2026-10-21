# ③ Registro de casos de uso — instanciado uma vez por entrada do mapa
# `use_cases`. Sem entrada no mapa, sem profile, sem role, sem acesso.
#
# Para cada caso:
# - uma application inference profile por modelo permitido (atribuição de
#   custo por tag e controle de região: copia o modelo in-region);
# - role IAM de menor privilégio (assumida pelo AgentCore Runtime do caso),
#   que só invoca os SEUS profiles, só com o SEU guardrail;
# - policy de bloqueio (não anexada) usada pela budget action em 100%.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  guardrail_identifier = "${var.guardrail.arn}:${var.guardrail.version}"

  foundation_model_arns = {
    for m in var.config.allowed_models : m => "arn:${local.partition}:bedrock:${local.region}::foundation-model/${m}"
  }

  uc_tags = {
    use_case            = var.name
    business_owner      = var.config.business_owner
    technical_owner     = var.config.technical_owner
    risk_classification = var.config.risk_classification
  }
}

# ------------------------------------------- Application inference profiles --
resource "aws_bedrock_inference_profile" "this" {
  for_each = local.foundation_model_arns

  # Nome curto e estável (limite de 64 caracteres); o modelo vai na descrição.
  name        = "${var.name_prefix}-${var.name}-${substr(md5(each.key), 0, 8)}"
  description = "Caso de uso ${var.name} — ${each.key}"

  model_source {
    copy_from = each.value
  }

  tags = merge(local.uc_tags, { model_id = each.key })
}

locals {
  profile_arns = [for p in aws_bedrock_inference_profile.this : p.arn]
}

# ----------------------------------------------------------------- Role ----
data "aws_iam_policy_document" "assume" {
  statement {
    sid     = "AgentCoreRuntime"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = "${var.name_prefix}-uc-${var.name}"
  description          = "Role de menor privilégio do caso de uso ${var.name}"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  max_session_duration = 3600
  permissions_boundary = var.permissions_boundary_arn

  tags = local.uc_tags
}

data "aws_iam_policy_document" "bedrock" {
  # 1) Invocar apenas as application inference profiles deste caso.
  statement {
    sid = "InvokeOwnInferenceProfiles"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = local.profile_arns
  }

  # 2) O Bedrock também autoriza o modelo de destino; só é permitido quando a
  #    chamada chega por um profile deste caso.
  statement {
    sid = "InvokeUnderlyingModelOnlyViaOwnProfiles"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = values(local.foundation_model_arns)
    condition {
      test     = "StringEquals"
      variable = "bedrock:InferenceProfileArn"
      values   = local.profile_arns
    }
  }

  # 3) Toda invocação precisa carregar o guardrail (e a versão) deste caso.
  statement {
    sid    = "DenyInvokeWithoutOwnGuardrail"
    effect = "Deny"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = concat(local.profile_arns, values(local.foundation_model_arns))
    condition {
      test     = "StringNotEquals"
      variable = "bedrock:GuardrailIdentifier"
      values   = [local.guardrail_identifier]
    }
  }

  # 4) ApplyGuardrail (checagens avulsas, ex.: saída de tools) só no seu guardrail.
  statement {
    sid       = "ApplyOwnGuardrail"
    actions   = ["bedrock:ApplyGuardrail"]
    resources = [var.guardrail.arn]
  }

  dynamic "statement" {
    for_each = var.config.knowledge_base_access && var.knowledge_base_arn != null ? [1] : []
    content {
      sid       = "RetrieveFromKnowledgeBase"
      actions   = ["bedrock:Retrieve"]
      resources = [var.knowledge_base_arn]
    }
  }
}

resource "aws_iam_role_policy" "bedrock" {
  name   = "bedrock-least-privilege"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.bedrock.json
}

# ------------------------------------------- Bloqueio por orçamento (100%) ---
data "aws_iam_policy_document" "budget_block" {
  statement {
    sid    = "BudgetExceededDenyInvoke"
    effect = "Deny"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = concat(local.profile_arns, values(local.foundation_model_arns))
  }
}

resource "aws_iam_policy" "budget_block" {
  name        = "${var.name_prefix}-uc-${var.name}-budget-block"
  description = "Anexada pela AWS Budgets action quando o caso ${var.name} atinge 100% do orçamento."
  policy      = data.aws_iam_policy_document.budget_block.json
  tags        = local.uc_tags
}
