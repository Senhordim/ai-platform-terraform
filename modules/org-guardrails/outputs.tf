output "policy_ids" {
  description = "IDs das SCPs criadas."
  value = {
    ai_region_and_models    = aws_organizations_policy.ai_region_and_models.id
    ai_logging_and_identity = aws_organizations_policy.ai_logging_and_identity.id
  }
}
