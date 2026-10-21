output "alb_endpoint" {
  description = "DNS interno do ALB (entrada da aplicação da central)."
  value       = module.ingress.alb_dns_name
}

output "gateway_arn" {
  description = "ARN do AgentCore Gateway (tools MCP)."
  value       = module.tool_gateway.gateway_arn
}

output "gateway_url" {
  description = "URL MCP do AgentCore Gateway."
  value       = module.tool_gateway.gateway_url
}

output "inference_profile_arns" {
  description = "Application inference profiles por caso de uso (caso => modelo => ARN)."
  value       = { for k, uc in module.use_case : k => uc.inference_profile_arns }
}

output "knowledge_base_id" {
  description = "ID da Bedrock Knowledge Base."
  value       = module.knowledge_base.knowledge_base_id
}

output "vpc_endpoint_ids" {
  description = "IDs dos VPC endpoints (interface, gateway S3 e OpenSearch Serverless)."
  value = merge(
    module.network.vpc_endpoint_ids,
    { aoss = module.knowledge_base.aoss_vpc_endpoint_id },
  )
}

output "kms_key_arns" {
  description = "ARNs das CMKs por domínio."
  value       = module.kms.key_arns
}

output "agent_runtime_arns" {
  description = "AgentCore Runtime por caso de uso."
  value       = { for k, r in module.agent_runtime : k => r.agent_runtime_arn }
}

output "agent_ecr_repositories" {
  description = "Repositórios ECR dos agentes (destino do pipeline de build)."
  value       = { for k, r in module.agent_runtime : k => r.ecr_repository_url }
}

output "use_case_role_policies" {
  description = "Policy IAM gerada por caso de uso — evidência de que cada caso só invoca seu profile e seu guardrail."
  value       = { for k, uc in module.use_case : k => jsondecode(uc.bedrock_policy_json) }
}

output "tool_catalog" {
  description = "Tools registradas (read/write) e se têm policy de permit."
  value       = module.tool_gateway.tool_catalog
}

output "outbound_identity_issuer" {
  description = "Issuer OIDC da conta para cadastrar no IdP (client de token exchange)."
  value       = module.tool_gateway.outbound_issuer
}

output "evaluation_bucket" {
  description = "Bucket de golden sets."
  value       = module.evaluation.bucket
}

output "evaluation_pipeline_role_arn" {
  description = "Role do pipeline de avaliação."
  value       = module.evaluation.pipeline_role_arn
}
