module "org_guardrails" {
  source = "../../modules/org-guardrails"

  name_prefix                  = var.name_prefix
  allowed_region               = "sa-east-1"
  allowed_model_ids            = var.allowed_model_ids
  target_ids                   = var.target_ids
  exempt_principal_arns        = var.exempt_principal_arns
  logging_admin_principal_arns = var.logging_admin_principal_arns
}
