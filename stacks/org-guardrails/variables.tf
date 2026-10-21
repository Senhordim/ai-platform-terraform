variable "management_account_id" {
  description = "ID da conta de gerenciamento da AWS Organizations."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.management_account_id))
    error_message = "ID de conta inválido."
  }
}

variable "name_prefix" {
  description = "Prefixo das SCPs."
  type        = string
  default     = "banco"
}

variable "allowed_model_ids" {
  description = "Allowlist de model IDs (mesma dos ambientes)."
  type        = list(string)
}

variable "target_ids" {
  description = "OUs/contas que recebem as SCPs."
  type        = list(string)
}

variable "exempt_principal_arns" {
  description = "Principais isentos da restrição de região (break-glass)."
  type        = list(string)
  default     = ["arn:aws:iam::*:role/OrganizationAccountAccessRole"]
}

variable "logging_admin_principal_arns" {
  description = "Principais autorizados a alterar CloudTrail/invocation logging."
  type        = list(string)
}

variable "owner" {
  description = "Time dono (tag owner)."
  type        = string
}

variable "cost_center" {
  description = "Centro de custo (tag cost_center)."
  type        = string
}
