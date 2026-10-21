variable "name_prefix" {
  description = "Prefixo de nomes."
  type        = string
}

variable "bucket_prefix" {
  description = "Prefixo globalmente único para buckets."
  type        = string
}

variable "use_cases" {
  description = "Casos de uso registrados (apenas os campos usados aqui). Um guardrail é criado por caso."
  type = map(object({
    risk_classification = string
  }))
}

variable "allowed_model_ids" {
  description = "Allowlist global de model IDs do Bedrock (in-region)."
  type        = list(string)

  validation {
    condition     = length(var.allowed_model_ids) > 0
    error_message = "A allowlist não pode ser vazia."
  }

  validation {
    condition     = alltrue([for m in var.allowed_model_ids : can(regex("^[a-z0-9-]+\\.[a-z0-9-]+(\\.[a-z0-9-]+)*(-v[0-9]+)?(:[0-9]+)?$", m))])
    error_message = "Formato inválido: use <provedor>.<modelo>[-vN][:N], ex.: amazon.titan-embed-text-v2:0."
  }

  validation {
    condition     = alltrue([for m in var.allowed_model_ids : !can(regex("^(us|eu|apac|jp|au|ca|us-gov|global)\\.", m))])
    error_message = "Perfis cross-region (us., eu., global. etc.) tiram a inferência de sa-east-1 e não são permitidos."
  }
}

variable "denied_topics" {
  description = "Tópicos negados no guardrail (nome => definição + exemplos)."
  type = map(object({
    definition = string
    examples   = list(string)
  }))
}

variable "grounding_threshold" {
  description = "Limiar do filtro de grounding contextual (0–0.99)."
  type        = number
  default     = 0.7
}

variable "relevance_threshold" {
  description = "Limiar do filtro de relevância contextual (0–0.99)."
  type        = number
  default     = 0.7
}

variable "blocked_input_message" {
  description = "Mensagem quando a entrada é bloqueada."
  type        = string
  default     = "Não posso ajudar com esta solicitação. Reformule ou acione o supervisor."
}

variable "blocked_output_message" {
  description = "Mensagem quando a resposta é bloqueada."
  type        = string
  default     = "A resposta foi bloqueada pela política de uso de IA do banco."
}

variable "guardrail_version_description" {
  description = "Descrição da versão publicada; altere para publicar nova versão."
  type        = string
  default     = "v1"
}

variable "data_kms_key_arn" {
  description = "CMK de dados (guardrails)."
  type        = string
}

variable "logs_kms_key_arn" {
  description = "CMK de logs (invocation logging)."
  type        = string
}

variable "access_log_bucket" {
  description = "Bucket de S3 access logs."
  type        = string
}

variable "log_retention_days" {
  description = "Retenção do log group de invocações (dias)."
  type        = number
}

variable "invocation_logs_expiration_days" {
  description = "Expiração dos invocation logs no S3 (dias)."
  type        = number
  default     = 1825
}

variable "force_destroy" {
  description = "Permite destruir o bucket com objetos (somente dev)."
  type        = bool
  default     = false
}
