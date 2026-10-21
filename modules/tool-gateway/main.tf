# ② Tool Gateway (MCP) = Bedrock AgentCore Gateway.
# - Entrada: JWT do IdP corporativo (o agente repassa o token do operador).
# - Saída: OAuth2 token exchange (RFC 8693) via AgentCore Identity — o core
#   recebe um token do PRÓPRIO operador, com escopo mínimo da tool, nunca uma
#   credencial do agente. O client do token exchange autentica no IdP com um
#   JWT assinado pela AWS (AWS_IAM_ID_TOKEN_JWT): nenhum client secret.
# - Policy in AgentCore (Cedar): permite apenas tools registradas como
#   leitura e exige o escopo da tool no token. Tudo o mais é negado.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  gateway_name       = "${var.name_prefix}-tools"
  policy_engine_name = substr(replace("${var.name_prefix}_tools", "-", "_"), 0, 48)

  read_tools  = { for k, t in var.tools : k => t if t.effect == "read" }
  write_tools = { for k, t in var.tools : k => t if t.effect == "write" }
}

# -------------------------------------------- AgentCore Identity (saída) ----
# Habilita a federação de identidade de saída da conta (issuer OIDC próprio
# da conta AWS). O IdP do banco deve confiar neste issuer como credencial
# federada do client de token exchange (ver output outbound_issuer).
resource "aws_iam_outbound_web_identity_federation" "this" {
  count = var.enable_outbound_identity_federation ? 1 : 0
}

resource "aws_bedrockagentcore_oauth2_credential_provider" "idp" {
  name                       = "${var.name_prefix}-idp-token-exchange"
  credential_provider_vendor = "CustomOauth2"

  oauth2_provider_config {
    custom_oauth2_provider_config {
      client_id                    = var.token_exchange_client_id
      client_authentication_method = var.token_exchange_client_auth_method

      oauth_discovery {
        discovery_url = var.idp_discovery_url
      }

      on_behalf_of_token_exchange_config {
        grant_type = var.token_exchange_grant_type

        dynamic "token_exchange_grant_type_config" {
          for_each = var.token_exchange_grant_type == "TOKEN_EXCHANGE" ? [1] : []
          content {
            actor_token_content = var.token_exchange_actor_token_content
          }
        }
      }
    }
  }

  depends_on = [aws_iam_outbound_web_identity_federation.this]
}

# ------------------------------------------------------- Gateway role ----
data "aws_iam_policy_document" "gateway_assume" {
  statement {
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
      values   = ["arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:gateway/*"]
    }
  }
}

resource "aws_iam_role" "gateway" {
  name               = "${var.name_prefix}-agentcore-gateway"
  assume_role_policy = data.aws_iam_policy_document.gateway_assume.json
}

data "aws_iam_policy_document" "gateway" {
  statement {
    sid = "TokenExchangeViaAgentCoreIdentity"
    actions = [
      "bedrock-agentcore:GetResourceOauth2Token",
      "bedrock-agentcore:GetWorkloadAccessToken",
      "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
    ]
    resources = [
      "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:token-vault/default",
      "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:token-vault/default/*",
      "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:workload-identity-directory/default",
      "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:workload-identity-directory/default/*",
      aws_bedrockagentcore_oauth2_credential_provider.idp.credential_provider_arn,
    ]
  }

  # TODO(validar): ações exigidas pelo Policy in AgentCore na role do gateway.
  statement {
    sid = "PolicyEngineEvaluation"
    actions = [
      "bedrock-agentcore:AuthorizeAction",
      "bedrock-agentcore:GetPolicyEngine",
      "bedrock-agentcore:PartiallyAuthorizeActions",
    ]
    resources = [
      aws_bedrockagentcore_policy_engine.this.policy_engine_arn,
      "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:gateway/*",
    ]
  }

  # Client assertion assinada pela AWS (AWS_IAM_ID_TOKEN_JWT).
  statement {
    sid       = "AwsIssuedJwtForClientAuth"
    actions   = ["sts:GetWebIdentityToken"]
    resources = ["*"] # sts:GetWebIdentityToken não suporta resource-level permissions.
  }

  statement {
    sid       = "GatewayEncryption"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.data_kms_key_arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["bedrock-agentcore.${local.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "gateway" {
  name   = "agentcore-gateway"
  role   = aws_iam_role.gateway.id
  policy = data.aws_iam_policy_document.gateway.json
}

# ------------------------------------------------ Policy in AgentCore ----
resource "aws_bedrockagentcore_policy_engine" "this" {
  name               = local.policy_engine_name
  description        = "Autorização por tool do gateway ${local.gateway_name}"
  encryption_key_arn = var.data_kms_key_arn
}

# --------------------------------------------------------------- Gateway --
resource "aws_bedrockagentcore_gateway" "this" {
  name            = local.gateway_name
  description     = "Tool gateway (MCP) da plataforma de agentes — tools somente leitura no piloto"
  role_arn        = aws_iam_role.gateway.arn
  protocol_type   = "MCP"
  authorizer_type = "CUSTOM_JWT"
  kms_key_arn     = var.data_kms_key_arn

  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url    = var.idp_discovery_url
      allowed_audience = var.idp_allowed_audiences
      allowed_clients  = length(var.idp_allowed_clients) > 0 ? var.idp_allowed_clients : null
    }
  }

  protocol_configuration {
    mcp {
      instructions = "Tools somente leitura para apoio ao operador da central. Toda ação com efeito exige um humano."
      search_type  = "SEMANTIC"
    }
  }

  policy_engine_configuration {
    arn  = aws_bedrockagentcore_policy_engine.this.policy_engine_arn
    mode = var.policy_enforcement_mode
  }

  lifecycle {
    precondition {
      condition     = var.allow_write_tools || length(local.write_tools) == 0
      error_message = "Há tools com efeito (write) no catálogo e allow_write_tools = false. O piloto só admite tools de leitura."
    }
  }

  depends_on = [aws_iam_role_policy.gateway]
}

# ------------------------------------------------- Observabilidade ----
resource "aws_cloudwatch_log_group" "gateway" {
  name              = "/aws/vendedlogs/bedrock-agentcore/${var.name_prefix}/gateway"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
}

resource "aws_cloudwatch_log_delivery_source" "gateway_logs" {
  name         = "${var.name_prefix}-gateway-logs"
  log_type     = "APPLICATION_LOGS"
  resource_arn = aws_bedrockagentcore_gateway.this.gateway_arn
}

resource "aws_cloudwatch_log_delivery_source" "gateway_traces" {
  name         = "${var.name_prefix}-gateway-traces"
  log_type     = "TRACES"
  resource_arn = aws_bedrockagentcore_gateway.this.gateway_arn
}

resource "aws_cloudwatch_log_delivery_destination" "gateway_logs" {
  name = "${var.name_prefix}-gateway-cwl"

  delivery_destination_configuration {
    destination_resource_arn = aws_cloudwatch_log_group.gateway.arn
  }
}

resource "aws_cloudwatch_log_delivery_destination" "gateway_traces" {
  name                      = "${var.name_prefix}-gateway-xray"
  delivery_destination_type = "XRAY"
}

resource "aws_cloudwatch_log_delivery" "gateway_logs" {
  delivery_source_name     = aws_cloudwatch_log_delivery_source.gateway_logs.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.gateway_logs.arn
}

resource "aws_cloudwatch_log_delivery" "gateway_traces" {
  delivery_source_name     = aws_cloudwatch_log_delivery_source.gateway_traces.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.gateway_traces.arn

  depends_on = [aws_cloudwatch_log_delivery.gateway_logs]
}
