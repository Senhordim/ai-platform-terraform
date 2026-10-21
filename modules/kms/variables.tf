variable "name_prefix" {
  description = "Prefixo de nomes (ex.: aip-dev)."
  type        = string
}

variable "key_admin_role_arns" {
  description = "ARNs de roles (SSO/pipeline) autorizadas a administrar as chaves. Sem uso criptográfico."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.key_admin_role_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+$", a))])
    error_message = "Cada item deve ser um ARN de role IAM."
  }
}

variable "rotation_period_in_days" {
  description = "Período de rotação automática (90–2560 dias)."
  type        = number
  default     = 365

  validation {
    condition     = var.rotation_period_in_days >= 90 && var.rotation_period_in_days <= 2560
    error_message = "rotation_period_in_days deve estar entre 90 e 2560."
  }
}

variable "deletion_window_in_days" {
  description = "Janela de exclusão das chaves (7–30 dias)."
  type        = number
  default     = 30

  validation {
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "deletion_window_in_days deve estar entre 7 e 30."
  }
}
