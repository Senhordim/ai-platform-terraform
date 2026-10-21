output "inference_profile_arns" {
  description = "ARN de cada application inference profile do caso (model_id => ARN)."
  value       = { for m, p in aws_bedrock_inference_profile.this : m => p.arn }
}

output "role_arn" {
  description = "ARN da role do caso de uso."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Nome da role do caso de uso."
  value       = aws_iam_role.this.name
}

output "budget_block_policy_arn" {
  description = "Policy de bloqueio usada pela budget action."
  value       = aws_iam_policy.budget_block.arn
}

output "bedrock_policy_json" {
  description = "Policy gerada (para revisão/teste de que o caso só invoca seu profile e seu guardrail)."
  value       = data.aws_iam_policy_document.bedrock.json
}
