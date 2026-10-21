output "alb_dns_name" {
  description = "DNS (interno) do ALB."
  value       = aws_lb.this.dns_name
}

output "alb_arn" {
  description = "ARN do ALB."
  value       = aws_lb.this.arn
}

output "web_acl_arn" {
  description = "ARN do Web ACL."
  value       = aws_wafv2_web_acl.this.arn
}

output "waf_log_group_name" {
  description = "Log group do WAF."
  value       = aws_cloudwatch_log_group.waf.name
}
