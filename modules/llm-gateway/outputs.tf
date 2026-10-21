output "allowed_model_ids" {
  description = "Allowlist de modelos (repassada às SCPs e aos casos de uso)."
  value       = var.allowed_model_ids
}

output "guardrails" {
  description = "Guardrail por caso de uso: id, arn e versão publicada."
  value = {
    for k, g in aws_bedrock_guardrail.this : k => {
      id      = g.guardrail_id
      arn     = g.guardrail_arn
      version = aws_bedrock_guardrail_version.this[k].version
    }
  }
}

output "invocation_log_group_name" {
  description = "Log group do model invocation logging."
  value       = aws_cloudwatch_log_group.invocations.name
}

output "invocation_logs_bucket" {
  description = "Bucket do model invocation logging."
  value       = module.invocation_logs_bucket.id
}
