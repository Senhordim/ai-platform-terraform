output "gateway_arn" {
  description = "ARN do AgentCore Gateway."
  value       = aws_bedrockagentcore_gateway.this.gateway_arn
}

output "gateway_id" {
  description = "ID do AgentCore Gateway."
  value       = aws_bedrockagentcore_gateway.this.gateway_id
}

output "gateway_url" {
  description = "URL MCP do AgentCore Gateway."
  value       = aws_bedrockagentcore_gateway.this.gateway_url
}

output "policy_engine_arn" {
  description = "ARN do policy engine (Cedar)."
  value       = aws_bedrockagentcore_policy_engine.this.policy_engine_arn
}

output "oauth2_credential_provider_arn" {
  description = "ARN do credential provider de token exchange."
  value       = aws_bedrockagentcore_oauth2_credential_provider.idp.credential_provider_arn
}

output "outbound_issuer" {
  description = "Issuer OIDC da conta AWS — cadastrar como credencial federada do client de token exchange no IdP."
  value       = try(aws_iam_outbound_web_identity_federation.this[0].issuer_identifier, null)
}

output "tool_catalog" {
  description = "Catálogo de tools: efeito (read/write), escopos e se há policy de permit."
  value = {
    for k, t in var.tools : k => {
      effect     = t.effect
      scopes     = t.oauth_scopes
      operations = t.operations
      permitted  = t.effect == "read"
    }
  }
}

output "core_api_id" {
  description = "ID do API Gateway privado do core."
  value       = aws_api_gateway_rest_api.core.id
}

output "core_api_base_url" {
  description = "URL base (privada) do API do core."
  value       = local.core_api_base_url
}

output "gateway_log_group_name" {
  description = "Log group do gateway."
  value       = aws_cloudwatch_log_group.gateway.name
}

output "core_api_log_group_name" {
  description = "Log group de access logs do API privado."
  value       = aws_cloudwatch_log_group.core_api.name
}
