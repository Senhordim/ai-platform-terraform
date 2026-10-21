variable "name_prefix" {
  description = "Prefixo de nomes (minúsculas)."
  type        = string
}

variable "bucket_prefix" {
  description = "Prefixo globalmente único para buckets."
  type        = string
}

variable "vpc_id" {
  description = "VPC do VPC endpoint do OpenSearch Serverless."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets do VPC endpoint do OpenSearch Serverless."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group do VPC endpoint do OpenSearch Serverless."
  type        = string
}

variable "embedding_model_id" {
  description = "Model ID do modelo de embeddings (in-region), ex.: amazon.titan-embed-text-v2:0."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+\\.[a-z0-9.-]+(:[0-9]+)?$", var.embedding_model_id))
    error_message = "Formato de model ID inválido."
  }
}

variable "embedding_dimensions" {
  description = "Dimensão dos vetores do modelo de embeddings."
  type        = number
  default     = 1024
}

variable "standby_replicas" {
  description = "Réplicas standby da coleção (DISABLED em dev, ENABLED em prd)."
  type        = string
  default     = "ENABLED"

  validation {
    condition     = contains(["ENABLED", "DISABLED"], var.standby_replicas)
    error_message = "Use ENABLED ou DISABLED."
  }
}

variable "aoss_admin_principal_arns" {
  description = "Principais (role do pipeline/Terraform) com permissão de gerir o índice."
  type        = list(string)
}

variable "document_prefixes" {
  description = "Prefixos do bucket ingeridos pela KB."
  type        = list(string)
  default     = ["documentos/"]
}

variable "chunk_max_tokens" {
  description = "Tamanho máximo do chunk (tokens)."
  type        = number
  default     = 300
}

variable "chunk_overlap_percentage" {
  description = "Sobreposição entre chunks (%)."
  type        = number
  default     = 20
}

variable "kb_kms_key_arn" {
  description = "CMK da knowledge base."
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
