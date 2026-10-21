# Targets do gateway: um por API do core, a partir da especificação OpenAPI
# (template com a URL base do API Gateway privado). O tráfego sai do gateway
# por VPC Lattice (private_endpoint) para o VPC endpoint execute-api desta VPC
# e nunca atravessa a internet.

locals {
  core_api_base_url = "https://${aws_api_gateway_rest_api.core.id}.execute-api.${local.region}.amazonaws.com/${aws_api_gateway_stage.core.stage_name}"
}

resource "aws_bedrockagentcore_gateway_target" "this" {
  for_each = var.tools

  gateway_identifier = aws_bedrockagentcore_gateway.this.gateway_id
  name               = each.key
  description        = "${each.value.description} [${upper(each.value.effect)}]"

  target_configuration {
    mcp {
      open_api_schema {
        inline_payload {
          payload = templatefile(each.value.openapi_spec_path, {
            base_url = local.core_api_base_url
          })
        }
      }
    }
  }

  # Token exchange: o core recebe um token do operador, com os escopos da tool.
  credential_provider_configuration {
    oauth {
      provider_arn = aws_bedrockagentcore_oauth2_credential_provider.idp.credential_provider_arn
      scopes       = each.value.oauth_scopes
      grant_type   = "TOKEN_EXCHANGE"
    }
  }

  private_endpoint {
    managed_vpc_resource {
      vpc_identifier           = var.vpc_id
      subnet_ids               = var.subnet_ids
      security_group_ids       = [var.security_group_id]
      endpoint_ip_address_type = "IPV4"
      # O domínio do API privado ({api-id}.execute-api...) é roteado pelo DNS
      # regional do VPC endpoint execute-api.
      routing_domain = var.execute_api_vpce_dns_name
    }
  }
}

# ----------------------------------------------------- Policies (Cedar) ----
# Uma policy por tool de LEITURA. Tools com efeito (write) ficam registradas
# no catálogo, mas sem policy de permit = negadas por padrão.
# Nome das ações MCP no gateway: <target>___<operationId>.
# TODO(validar no 1º apply): esquema de entidades Cedar do AgentCore
# (AgentCore::OAuthUser / AgentCore::Action / AgentCore::Gateway) e o nome do
# claim de escopo (scope em Okta, scp em Entra ID).
resource "aws_bedrockagentcore_policy" "read_tool" {
  for_each = local.read_tools

  name             = substr(replace("allow_${each.key}", "-", "_"), 0, 48)
  policy_engine_id = aws_bedrockagentcore_policy_engine.this.policy_engine_id
  description      = "Permite as operações de leitura da tool ${each.key} para quem tem o escopo ${join(", ", each.value.oauth_scopes)}"
  validation_mode  = var.policy_validation_mode

  definition {
    cedar {
      statement = <<-EOT
        permit(
          principal is AgentCore::OAuthUser,
          action in [${join(", ", [for op in each.value.operations : "AgentCore::Action::\"${each.key}___${op}\""])}],
          resource == AgentCore::Gateway::"${aws_bedrockagentcore_gateway.this.gateway_arn}"
        ) when {
          principal.hasTag("${var.scope_claim_name}") &&
          principal.getTag("${var.scope_claim_name}") like "*${each.value.oauth_scopes[0]}*"
        };
      EOT
    }
  }

  depends_on = [aws_bedrockagentcore_gateway_target.this]
}
