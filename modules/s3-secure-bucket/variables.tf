variable "name" {
  description = "Nome globalmente único do bucket."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.name))
    error_message = "Nome de bucket S3 inválido."
  }
}

variable "kms_key_arn" {
  description = "ARN da CMK usada no SSE-KMS. null = SSE-S3 (apenas para ALB access logs, que não aceitam CMK)."
  type        = string
  default     = null
}

variable "deny_unencrypted_uploads" {
  description = "Nega PutObject com chave KMS diferente da CMK do bucket."
  type        = bool
  default     = false
}

variable "object_lock" {
  description = "Configuração de Object Lock (WORM). null desabilita."
  type = object({
    mode           = string
    retention_days = number
  })
  default = null

  validation {
    condition     = var.object_lock == null || contains(["GOVERNANCE", "COMPLIANCE"], try(var.object_lock.mode, ""))
    error_message = "object_lock.mode deve ser GOVERNANCE ou COMPLIANCE."
  }
}

variable "access_log_bucket" {
  description = "Bucket que recebe os server access logs deste bucket. null desabilita."
  type        = string
  default     = null
}

variable "additional_policy_json" {
  description = "Policy JSON adicional mesclada à bucket policy (ex.: permissões de serviço)."
  type        = string
  default     = null
}

variable "noncurrent_version_expiration_days" {
  description = "Dias até expirar versões não correntes. null mantém para sempre."
  type        = number
  default     = 365
}

variable "expiration_days" {
  description = "Dias até expirar objetos correntes. null mantém para sempre."
  type        = number
  default     = null
}

variable "force_destroy" {
  description = "Permite destruir o bucket com objetos (somente dev)."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags adicionais."
  type        = map(string)
  default     = {}
}
