variable "name_prefix" {
  description = "Prefixo de nomes (ex.: aip-dev)."
  type        = string
}

variable "bucket_prefix" {
  description = "Prefixo globalmente único para buckets (ex.: banco-aip-dev-123456789012)."
  type        = string
}

variable "logs_kms_key_arn" {
  description = "CMK de logs."
  type        = string
}

variable "log_retention_days" {
  description = "Retenção dos log groups (dias)."
  type        = number
}

variable "cloudtrail_object_lock_mode" {
  description = "Modo do Object Lock do bucket do CloudTrail (GOVERNANCE em dev, COMPLIANCE em prd)."
  type        = string

  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.cloudtrail_object_lock_mode)
    error_message = "Use GOVERNANCE ou COMPLIANCE."
  }
}

variable "cloudtrail_object_lock_days" {
  description = "Retenção WORM dos logs do CloudTrail (dias)."
  type        = number

  validation {
    condition     = var.cloudtrail_object_lock_days >= 1
    error_message = "Retenção mínima de 1 dia."
  }
}

variable "cloudtrail_data_event_bucket_arns" {
  description = "Buckets com data events (GetObject/PutObject) no CloudTrail — documentos, golden sets."
  type        = list(string)
  default     = []
}

variable "xray_indexing_percentage" {
  description = "Percentual de spans indexados no Transaction Search (1% é gratuito)."
  type        = number
  default     = 1

  validation {
    condition     = var.xray_indexing_percentage > 0 && var.xray_indexing_percentage <= 100
    error_message = "Entre 0 e 100."
  }
}

variable "siem_destination_arn" {
  description = "ARN do CloudWatch Logs destination (conta do SIEM). null desliga a exportação."
  type        = string
  default     = null

  validation {
    condition     = var.siem_destination_arn == null || can(regex("^arn:aws[a-z-]*:logs:sa-east-1:[0-9]{12}:destination:.+$", var.siem_destination_arn))
    error_message = "Use um ARN de CloudWatch Logs destination em sa-east-1."
  }
}

variable "siem_log_group_names" {
  description = "Mapa estático (chave => nome do log group) enviado ao SIEM."
  type        = map(string)
  default     = {}
}

variable "access_logs_expiration_days" {
  description = "Expiração dos S3 access logs (dias)."
  type        = number
  default     = 400
}

variable "force_destroy" {
  description = "Permite destruir buckets não-WORM com objetos (somente dev)."
  type        = bool
  default     = false
}
