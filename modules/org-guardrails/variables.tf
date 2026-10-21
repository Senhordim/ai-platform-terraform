variable "name_prefix" {
  description = "Prefixo dos nomes das SCPs."
  type        = string
  default     = "banco"
}

variable "allowed_region" {
  description = "Única região permitida para Bedrock/AgentCore."
  type        = string
  default     = "sa-east-1"

  validation {
    condition     = var.allowed_region == "sa-east-1"
    error_message = "Residência de dados: apenas sa-east-1."
  }
}

variable "allowed_model_ids" {
  description = "Allowlist de model IDs (a mesma usada nos ambientes)."
  type        = list(string)

  validation {
    condition     = length(var.allowed_model_ids) > 0 && alltrue([for m in var.allowed_model_ids : can(regex("^[a-z0-9-]+\\.[a-z0-9.:-]+$", m))])
    error_message = "Informe model IDs válidos."
  }
}

variable "target_ids" {
  description = "OUs (ou-xxxx) ou contas onde as SCPs serão anexadas (ex.: OU de workloads de IA)."
  type        = list(string)

  validation {
    condition     = alltrue([for t in var.target_ids : can(regex("^(ou-[a-z0-9]{4,32}-[a-z0-9]{8,32}|[0-9]{12}|r-[a-z0-9]{4,32})$", t))])
    error_message = "Use IDs de OU, conta ou root."
  }
}

variable "exempt_principal_arns" {
  description = "Principais isentos da restrição de região (ex.: role break-glass). Aceita curingas de ARN."
  type        = list(string)
  default     = ["arn:aws:iam::*:role/OrganizationAccountAccessRole"]
}

variable "logging_admin_principal_arns" {
  description = "Únicos principais que podem alterar CloudTrail/invocation logging (pipeline de IaC da plataforma)."
  type        = list(string)
}
