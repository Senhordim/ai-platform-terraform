variable "name_prefix" {
  description = "Prefixo de nomes."
  type        = string
}

variable "name" {
  description = "Identificador do caso de uso (chave do mapa use_cases)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.name))
    error_message = "Use minúsculas, números e hífen (3–31 caracteres)."
  }
}

variable "config" {
  description = "Entrada do registro de casos de uso."
  type = object({
    display_name          = string
    business_owner        = string
    technical_owner       = string
    risk_classification   = string
    allowed_models        = list(string)
    allowed_tools         = list(string)
    monthly_budget_usd    = number
    knowledge_base_access = bool
    container_image_tag   = string
  })

  validation {
    condition     = contains(["baixo", "medio", "alto", "critico"], var.config.risk_classification)
    error_message = "risk_classification deve ser baixo, medio, alto ou critico."
  }

  validation {
    condition     = length(var.config.allowed_models) > 0
    error_message = "O caso de uso precisa de ao menos um modelo."
  }
}

variable "guardrail" {
  description = "Guardrail do caso (id, arn, versão publicada)."
  type = object({
    id      = string
    arn     = string
    version = string
  })
}

variable "knowledge_base_arn" {
  description = "ARN da knowledge base (null = sem RAG)."
  type        = string
  default     = null
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary aplicada à role (opcional, recomendada)."
  type        = string
  default     = null
}
