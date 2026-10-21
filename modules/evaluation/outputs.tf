output "bucket" {
  description = "Bucket de golden sets e resultados."
  value       = module.golden_sets_bucket.id
}

output "bucket_arn" {
  description = "ARN do bucket de avaliação."
  value       = module.golden_sets_bucket.arn
}

output "pipeline_role_arn" {
  description = "Role assumida pelo pipeline de avaliação."
  value       = aws_iam_role.pipeline.arn
}
