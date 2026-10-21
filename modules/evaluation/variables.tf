variable "name_prefix" {
  description = "Prefixo de nomes."
  type        = string
}

variable "bucket_prefix" {
  description = "Prefixo globalmente único para buckets."
  type        = string
}

variable "use_case_names" {
  description = "Casos de uso (um prefixo de golden set por caso)."
  type        = list(string)
}

variable "agent_runtime_arns" {
  description = "ARNs dos runtimes avaliados pelo pipeline."
  type        = list(string)
  default     = []
}

variable "ci_oidc_provider_arn" {
  description = "ARN do IAM OIDC provider do CI (ex.: GitHub Actions, GitLab)."
  type        = string
}

variable "ci_oidc_provider_host" {
  description = "Host do issuer OIDC do CI (ex.: token.actions.githubusercontent.com)."
  type        = string
}

variable "ci_oidc_audience" {
  description = "Audience esperada no token do CI."
  type        = string
  default     = "sts.amazonaws.com"
}

variable "ci_oidc_subjects" {
  description = "Subjects permitidos (ex.: repo:banco/ai-platform:environment:dev)."
  type        = list(string)
}

variable "data_kms_key_arn" {
  description = "CMK de dados."
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
