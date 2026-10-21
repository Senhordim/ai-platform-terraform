variable "name_prefix" {
  description = "Prefixo de nomes."
  type        = string
}

variable "bucket_prefix" {
  description = "Prefixo globalmente único para buckets."
  type        = string
}

variable "vpc_id" {
  description = "VPC."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR da VPC (egress do ALB para os targets)."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets privadas do ALB."
  type        = list(string)
}

variable "allowed_client_cidrs" {
  description = "CIDRs da rede corporativa (estações da central) que acessam o ALB."
  type        = list(string)

  validation {
    condition     = length(var.allowed_client_cidrs) > 0 && alltrue([for c in var.allowed_client_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "Informe CIDRs corporativos válidos (0.0.0.0/0 não é permitido)."
  }
}

variable "idp_egress_cidrs" {
  description = "CIDRs do IdP quando hospedado on-prem/privado (opcional)."
  type        = list(string)
  default     = []
}

variable "idp_egress_via_firewall" {
  description = "Libera saída 443 do ALB para o IdP SaaS (filtrada por domínio no Network Firewall; exige egress_allowed_domains)."
  type        = bool
  default     = false
}

variable "certificate_arn" {
  description = "ARN do certificado ACM (CA privada do banco ou pública) do listener HTTPS."
  type        = string
}

variable "oidc" {
  description = "Endpoints e client do IdP para authenticate-oidc."
  type = object({
    issuer                 = string
    authorization_endpoint = string
    token_endpoint         = string
    user_info_endpoint     = string
    client_id              = string
    scope                  = string
  })
}

variable "oidc_client_secret_arn" {
  description = "ARN do segredo (Secrets Manager) com o client secret do IdP para o ALB."
  type        = string
}

variable "oidc_session_timeout_seconds" {
  description = "Duração da sessão autenticada no ALB (s)."
  type        = number
  default     = 28800
}

variable "target_port" {
  description = "Porta HTTPS da aplicação da central (BFF)."
  type        = number
  default     = 443
}

variable "target_ips" {
  description = "IPs da aplicação da central (BFF) registrados no target group."
  type        = list(string)
  default     = []
}

variable "health_check_path" {
  description = "Path de health check do BFF."
  type        = string
  default     = "/health"
}

variable "waf_rate_limit_per_5min" {
  description = "Limite de requisições por IP a cada 5 minutos."
  type        = number
  default     = 2000
}

variable "logs_kms_key_arn" {
  description = "CMK de logs (WAF)."
  type        = string
}

variable "log_retention_days" {
  description = "Retenção dos logs (dias)."
  type        = number
}

variable "access_log_bucket" {
  description = "Bucket de S3 access logs."
  type        = string
}

variable "alb_logs_expiration_days" {
  description = "Expiração dos access logs do ALB (dias)."
  type        = number
  default     = 400
}

variable "deletion_protection" {
  description = "Proteção contra exclusão do ALB."
  type        = bool
  default     = true
}

variable "force_destroy" {
  description = "Permite destruir o bucket com objetos (somente dev)."
  type        = bool
  default     = false
}
