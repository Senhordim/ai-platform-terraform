# ① LLM Gateway = Amazon Bedrock.
# - Allowlist de modelos (variável) — validada aqui e reaplicada nas SCPs.
# - Um Bedrock Guardrail por caso de uso (filtros de conteúdo, PII com
#   mascaramento, tópicos negados, prompt attack), com versão publicada.
# - Model invocation logging para S3 (CMK) e CloudWatch Logs.
# As application inference profiles (uma por caso de uso) ficam no módulo
# use-case, junto com a role que só pode invocá-las.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  # PII nativa do Guardrail (mascarada = ANONYMIZE).
  native_pii = [
    "EMAIL",
    "PHONE",
    "CREDIT_DEBIT_CARD_NUMBER",
    "CREDIT_DEBIT_CARD_CVV",
    "CREDIT_DEBIT_CARD_EXPIRY",
    "PIN",
    "PASSWORD",
    "AWS_ACCESS_KEY",
    "AWS_SECRET_KEY",
  ]

  # PII brasileira sem tipo nativo: regex customizadas.
  br_pii_regexes = {
    cpf = {
      description = "CPF (com ou sem máscara)"
      pattern     = "\\b\\d{3}\\.?\\d{3}\\.?\\d{3}-?\\d{2}\\b"
    }
    cnpj = {
      description = "CNPJ (com ou sem máscara)"
      pattern     = "\\b\\d{2}\\.?\\d{3}\\.?\\d{3}/?\\d{4}-?\\d{2}\\b"
    }
    agencia_conta = {
      description = "Agência e conta (ex.: ag 1234 cc 12345-6)"
      pattern     = "(?i)\\b(ag(\\.|ência|encia)?\\s*:?\\s*\\d{3,5}(-\\d)?)\\s*(c(\\/|\\.)?c|conta)\\s*:?\\s*\\d{4,12}-?[\\dxX]\\b"
    }
    chave_pix_aleatoria = {
      description = "Chave PIX aleatória (UUID)"
      pattern     = "\\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\b"
    }
  }

  content_filters = ["SEXUAL", "VIOLENCE", "HATE", "INSULTS", "MISCONDUCT"]
}

# -------------------------------------------------------------- Guardrails --
resource "aws_bedrock_guardrail" "this" {
  for_each = var.use_cases

  name                      = "${var.name_prefix}-${each.key}"
  description               = "Guardrail do caso de uso ${each.key} (risco ${each.value.risk_classification})"
  kms_key_arn               = var.data_kms_key_arn
  blocked_input_messaging   = var.blocked_input_message
  blocked_outputs_messaging = var.blocked_output_message

  content_policy_config {
    dynamic "filters_config" {
      for_each = local.content_filters
      content {
        type            = filters_config.value
        input_strength  = "HIGH"
        output_strength = "HIGH"
      }
    }

    # Proteção contra prompt attack (só se aplica à entrada).
    filters_config {
      type            = "PROMPT_ATTACK"
      input_strength  = "HIGH"
      output_strength = "NONE"
    }
  }

  sensitive_information_policy_config {
    dynamic "pii_entities_config" {
      for_each = local.native_pii
      content {
        type   = pii_entities_config.value
        action = "ANONYMIZE"
      }
    }

    dynamic "regexes_config" {
      for_each = local.br_pii_regexes
      content {
        name        = regexes_config.key
        description = regexes_config.value.description
        pattern     = regexes_config.value.pattern
        action      = "ANONYMIZE"
      }
    }
  }

  topic_policy_config {
    dynamic "topics_config" {
      for_each = var.denied_topics
      content {
        name       = topics_config.key
        definition = topics_config.value.definition
        examples   = topics_config.value.examples
        type       = "DENY"
      }
    }
  }

  contextual_grounding_policy_config {
    filters_config {
      type      = "GROUNDING"
      threshold = var.grounding_threshold
    }
    filters_config {
      type      = "RELEVANCE"
      threshold = var.relevance_threshold
    }
  }

  tags = {
    use_case            = each.key
    risk_classification = each.value.risk_classification
  }
}

# Versão publicada (imutável). Mude guardrail_version_description para
# publicar uma nova versão após alterar o guardrail.
resource "aws_bedrock_guardrail_version" "this" {
  for_each = var.use_cases

  guardrail_arn = aws_bedrock_guardrail.this[each.key].guardrail_arn
  description   = var.guardrail_version_description
  skip_destroy  = true
}

# ----------------------------------------------- Model invocation logging --
module "invocation_logs_bucket" {
  source = "../s3-secure-bucket"

  name                   = "${var.bucket_prefix}-bedrock-invocations"
  kms_key_arn            = var.logs_kms_key_arn
  access_log_bucket      = var.access_log_bucket
  expiration_days        = var.invocation_logs_expiration_days
  force_destroy          = var.force_destroy
  additional_policy_json = data.aws_iam_policy_document.invocation_bucket.json
}

data "aws_iam_policy_document" "invocation_bucket" {
  statement {
    sid       = "AmazonBedrockLogsWrite"
    actions   = ["s3:PutObject"]
    resources = ["arn:${local.partition}:s3:::${var.bucket_prefix}-bedrock-invocations/*"]
    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:bedrock:${local.region}:${local.account_id}:*"]
    }
  }
}

resource "aws_cloudwatch_log_group" "invocations" {
  name              = "/aws/bedrock/${var.name_prefix}/model-invocations"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
}

data "aws_iam_policy_document" "bedrock_logging_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:bedrock:${local.region}:${local.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "bedrock_logging" {
  name               = "${var.name_prefix}-bedrock-invocation-logging"
  assume_role_policy = data.aws_iam_policy_document.bedrock_logging_assume.json
}

data "aws_iam_policy_document" "bedrock_logging" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.invocations.arn}:log-stream:*"]
  }

  statement {
    actions   = ["s3:PutObject"]
    resources = ["${module.invocation_logs_bucket.arn}/large-payloads/*"]
  }
}

resource "aws_iam_role_policy" "bedrock_logging" {
  name   = "write-invocation-logs"
  role   = aws_iam_role.bedrock_logging.id
  policy = data.aws_iam_policy_document.bedrock_logging.json
}

resource "aws_bedrock_model_invocation_logging_configuration" "this" {
  logging_config {
    text_data_delivery_enabled      = true
    image_data_delivery_enabled     = true
    embedding_data_delivery_enabled = false
    video_data_delivery_enabled     = false

    cloudwatch_config {
      log_group_name = aws_cloudwatch_log_group.invocations.name
      role_arn       = aws_iam_role.bedrock_logging.arn

      large_data_delivery_s3_config {
        bucket_name = module.invocation_logs_bucket.id
        key_prefix  = "large-payloads"
      }
    }

    s3_config {
      bucket_name = module.invocation_logs_bucket.id
      key_prefix  = "invocations"
    }
  }

  depends_on = [
    module.invocation_logs_bucket,
    aws_iam_role_policy.bedrock_logging,
  ]
}
