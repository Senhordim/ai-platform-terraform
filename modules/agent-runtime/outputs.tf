output "agent_runtime_arn" {
  description = "ARN do AgentCore Runtime."
  value       = aws_bedrockagentcore_agent_runtime.this.agent_runtime_arn
}

output "agent_runtime_endpoint_arn" {
  description = "ARN do endpoint estável do runtime."
  value       = aws_bedrockagentcore_agent_runtime_endpoint.this.agent_runtime_endpoint_arn
}

output "ecr_repository_url" {
  description = "Repositório ECR do agente."
  value       = aws_ecr_repository.this.repository_url
}

output "workload_identity_arn" {
  description = "ARN da workload identity do agente."
  value       = aws_bedrockagentcore_workload_identity.this.workload_identity_arn
}

output "log_group_name" {
  description = "Log group de aplicação do agente."
  value       = aws_cloudwatch_log_group.app.name
}
