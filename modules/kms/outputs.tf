output "key_arns" {
  description = "ARNs das CMKs por domínio (logs, data, kb)."
  value       = { for k, v in aws_kms_key.this : k => v.arn }
}

output "logs_key_arn" {
  description = "ARN da CMK de logs."
  value       = aws_kms_key.this["logs"].arn
}

output "data_key_arn" {
  description = "ARN da CMK de dados."
  value       = aws_kms_key.this["data"].arn
}

output "kb_key_arn" {
  description = "ARN da CMK da knowledge base."
  value       = aws_kms_key.this["kb"].arn
}
