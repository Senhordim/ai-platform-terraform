variable "name_prefix" {
  description = "Prefixo de nomes."
  type        = string
}

variable "bucket_prefix" {
  description = "Prefixo globalmente único para buckets."
  type        = string
}

variable "logs_kms_key_arn" {
  description = "CMK de logs (bucket do Config)."
  type        = string
}

variable "access_log_bucket" {
  description = "Bucket de S3 access logs."
  type        = string
}

variable "enable_config" {
  description = "Habilita AWS Config nesta conta (desligue se gerenciado pela organização)."
  type        = bool
  default     = true
}

variable "create_config_service_linked_role" {
  description = "Cria a service-linked role do Config (false se já existir na conta)."
  type        = bool
  default     = true
}

variable "enable_guardduty" {
  description = "Habilita GuardDuty (desligue se gerenciado por administrador delegado)."
  type        = bool
  default     = true
}

variable "enable_macie" {
  description = "Habilita Macie."
  type        = bool
  default     = true
}

variable "macie_bucket_names" {
  description = "Buckets inspecionados pelo Macie (documentos da knowledge base)."
  type        = list(string)
  default     = []
}

variable "force_destroy" {
  description = "Permite destruir buckets com objetos (somente dev)."
  type        = bool
  default     = false
}
