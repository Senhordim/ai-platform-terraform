output "access_log_bucket" {
  description = "Bucket central de S3 server access logs."
  value       = module.access_logs_bucket.id
}

output "cloudtrail_arn" {
  description = "ARN do trail."
  value       = aws_cloudtrail.this.arn
}

output "cloudtrail_bucket" {
  description = "Bucket WORM do CloudTrail."
  value       = module.cloudtrail_bucket.id
}

output "cloudtrail_log_group_name" {
  description = "Log group do CloudTrail."
  value       = aws_cloudwatch_log_group.cloudtrail.name
}
