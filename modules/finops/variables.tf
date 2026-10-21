variable "name_prefix" {
  description = "Prefixo de nomes."
  type        = string
}

variable "bucket_prefix" {
  description = "Prefixo globalmente único para buckets."
  type        = string
}

variable "use_cases" {
  description = "Por caso de uso: orçamento mensal e a role/policy alvo da budget action."
  type = map(object({
    monthly_budget_usd = number
    role_arn           = string
    role_name          = string
    block_policy_arn   = string
  }))

  validation {
    condition     = alltrue([for k, v in var.use_cases : v.monthly_budget_usd > 0])
    error_message = "monthly_budget_usd deve ser maior que zero."
  }
}

variable "budget_alert_emails" {
  description = "E-mails notificados pelos budgets."
  type        = list(string)
  default     = []
}

variable "budget_alert_sns_topic_arns" {
  description = "Tópicos SNS notificados pelos budgets."
  type        = list(string)
  default     = []
}

variable "enable_cur_export" {
  description = "Cria a exportação CUR 2.0 (desligue se o banco centraliza o CUR na conta de gerenciamento)."
  type        = bool
  default     = true
}

variable "data_kms_key_arn" {
  description = "CMK de dados (bucket do CUR)."
  type        = string
}

variable "access_log_bucket" {
  description = "Bucket de S3 access logs."
  type        = string
}

variable "force_destroy" {
  description = "Permite destruir o bucket com objetos (somente dev)."
  type        = bool
  default     = false
}
