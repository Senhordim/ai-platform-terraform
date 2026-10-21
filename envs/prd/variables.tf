# ------------------------------------------------------------- Conta ----
variable "region" {
  description = "Região única da plataforma (residência de dados)."
  type        = string
  default     = "sa-east-1"

  validation {
    condition     = var.region == "sa-east-1"
    error_message = "Residência de dados: a plataforma só pode ser criada em sa-east-1."
  }
}

variable "environment" {
  description = "Ambiente."
  type        = string

  validation {
    condition     = contains(["dev", "prd"], var.environment)
    error_message = "environment deve ser dev ou prd."
  }
}

variable "account_id" {
  description = "ID da conta de workload \"AI Platform\" (trava de segurança do provider)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "ID de conta inválido."
  }
}

variable "bucket_namespace" {
  description = "Prefixo do banco para nomes de bucket globalmente únicos (ex.: banco)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{2,20}$", var.bucket_namespace))
    error_message = "Use minúsculas, números e hífen (2–20)."
  }
}

# --------------------------------------------------------------- Tags ----
variable "project" {
  description = "Tag project."
  type        = string
  default     = "ai-platform"
}

variable "owner" {
  description = "Tag owner (time dono da plataforma)."
  type        = string
}

variable "cost_center" {
  description = "Tag cost_center."
  type        = string
}

variable "data_classification" {
  description = "Tag data_classification padrão da conta."
  type        = string
  default     = "confidencial"

  validation {
    condition     = contains(["publico", "interno", "confidencial", "restrito"], var.data_classification)
    error_message = "Use publico, interno, confidencial ou restrito."
  }
}

# -------------------------------------------------------------- Rede ----
variable "vpc_cidr" {
  description = "CIDR /16 da VPC."
  type        = string
}

variable "transit_gateway_id" {
  description = "TGW compartilhado que alcança o data center (Direct Connect). null = sem attachment."
  type        = string
  default     = null
}

variable "onprem_cidrs" {
  description = "CIDRs do data center (APIs do core)."
  type        = list(string)
  default     = []
}

variable "egress_allowed_domains" {
  description = "Allowlist de domínios para egress externo via Network Firewall. Vazia = sem egress."
  type        = list(string)
  default     = []
}

variable "additional_interface_endpoint_services" {
  description = "VPC endpoints de interface adicionais."
  type        = list(string)
  default     = []
}

# --------------------------------------------------------- Segurança ----
variable "key_admin_role_arns" {
  description = "Roles administradoras das CMKs."
  type        = list(string)
  default     = []
}

variable "platform_admin_role_arns" {
  description = "Roles do pipeline/Terraform com permissão de gerir o índice vetorial."
  type        = list(string)
}

variable "enable_config" {
  description = "Habilita AWS Config na conta."
  type        = bool
  default     = true
}

variable "create_config_service_linked_role" {
  description = "Cria a service-linked role do Config."
  type        = bool
  default     = true
}

variable "enable_guardduty" {
  description = "Habilita GuardDuty na conta."
  type        = bool
  default     = true
}

variable "enable_macie" {
  description = "Habilita Macie na conta."
  type        = bool
  default     = true
}

# ---------------------------------------------------- Observabilidade ----
variable "log_retention_days" {
  description = "Retenção dos CloudWatch Logs (dias)."
  type        = number

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "Use um valor de retenção aceito pelo CloudWatch Logs."
  }
}

variable "cloudtrail_object_lock_mode" {
  description = "Modo do Object Lock do bucket do CloudTrail."
  type        = string
}

variable "cloudtrail_object_lock_days" {
  description = "Retenção WORM do CloudTrail (dias)."
  type        = number
}

variable "siem_destination_arn" {
  description = "CloudWatch Logs destination do SIEM (null desliga)."
  type        = string
  default     = null
}

# ------------------------------------------------------ LLM Gateway ----
variable "allowed_model_ids" {
  description = "Allowlist global de model IDs (in-region). Repetida nas SCPs."
  type        = list(string)
}

variable "denied_topics" {
  description = "Tópicos negados nos guardrails."
  type = map(object({
    definition = string
    examples   = list(string)
  }))
}

# ------------------------------------------------- Registro de casos ----
variable "use_cases" {
  description = "Registro de casos de uso. Sem entrada aqui, sem acesso."
  type = map(object({
    display_name          = string
    business_owner        = string
    technical_owner       = string
    risk_classification   = string
    allowed_models        = list(string)
    allowed_tools         = list(string)
    monthly_budget_usd    = number
    knowledge_base_access = bool
    container_image_tag   = string
  }))

  validation {
    condition     = alltrue([for k in keys(var.use_cases) : can(regex("^[a-z][a-z0-9-]{2,30}$", k))])
    error_message = "Chaves de use_cases: minúsculas, números e hífen (3–31)."
  }

  validation {
    condition     = alltrue([for k, v in var.use_cases : contains(["baixo", "medio", "alto", "critico"], v.risk_classification)])
    error_message = "risk_classification deve ser baixo, medio, alto ou critico."
  }
}

# ----------------------------------------------------- Tool Gateway ----
variable "tools" {
  description = "Catálogo de tools do AgentCore Gateway."
  type = map(object({
    description       = string
    effect            = string
    openapi_spec_path = string
    core_base_path    = string
    operations        = list(string)
    oauth_scopes      = list(string)
  }))
}

variable "policy_enforcement_mode" {
  description = "Policy in AgentCore: LOG_ONLY ou ENFORCE."
  type        = string
}

variable "idp_discovery_url" {
  description = "OIDC discovery URL do IdP."
  type        = string
}

variable "idp_allowed_audiences" {
  description = "Audiences aceitas no token do operador."
  type        = list(string)
}

variable "idp_allowed_clients" {
  description = "Client IDs aceitos (opcional)."
  type        = list(string)
  default     = []
}

variable "idp_scope_claim_name" {
  description = "Claim de escopos no token (scope/scp)."
  type        = string
  default     = "scope"
}

variable "token_exchange_client_id" {
  description = "Client ID do token exchange de saída."
  type        = string
}

variable "token_exchange_grant_type" {
  description = "TOKEN_EXCHANGE (RFC 8693) ou JWT_AUTHORIZATION_GRANT (OBO)."
  type        = string
  default     = "TOKEN_EXCHANGE"
}

variable "enable_outbound_identity_federation" {
  description = "Habilita a outbound web identity federation da conta."
  type        = bool
  default     = true
}

variable "core_api_hostname" {
  description = "Hostname TLS das APIs do core."
  type        = string
}

variable "core_target_ips" {
  description = "IPs das APIs do core (via Direct Connect)."
  type        = list(string)
}

variable "manage_apigw_account_settings" {
  description = "Gerencia a role de CloudWatch da conta do API Gateway."
  type        = bool
  default     = true
}

# ----------------------------------------------------- Knowledge Base ----
variable "embedding_model_id" {
  description = "Modelo de embeddings da KB (precisa estar na allowlist)."
  type        = string
}

variable "embedding_dimensions" {
  description = "Dimensão dos embeddings."
  type        = number
  default     = 1024
}

variable "aoss_standby_replicas" {
  description = "Réplicas standby do OpenSearch Serverless."
  type        = string
  default     = "ENABLED"
}

# ------------------------------------------------------------ Entrada ----
variable "alb_certificate_arn" {
  description = "Certificado ACM do listener HTTPS."
  type        = string
}

variable "alb_allowed_client_cidrs" {
  description = "CIDRs corporativos com acesso ao ALB."
  type        = list(string)
}

variable "alb_oidc" {
  description = "Configuração authenticate-oidc do ALB."
  type = object({
    issuer                 = string
    authorization_endpoint = string
    token_endpoint         = string
    user_info_endpoint     = string
    client_id              = string
    scope                  = string
  })
}

variable "alb_oidc_client_secret_arn" {
  description = "Segredo (Secrets Manager) com o client secret do ALB no IdP."
  type        = string
}

variable "alb_target_ips" {
  description = "IPs do BFF da central."
  type        = list(string)
  default     = []
}

variable "alb_idp_egress_via_firewall" {
  description = "Libera saída do ALB ao IdP SaaS via Network Firewall."
  type        = bool
  default     = false
}

variable "alb_idp_egress_cidrs" {
  description = "CIDRs do IdP quando alcançável por rota privada."
  type        = list(string)
  default     = []
}

# ------------------------------------------------------------ Avaliação ----
variable "ci_oidc_provider_arn" {
  description = "IAM OIDC provider do CI."
  type        = string
}

variable "ci_oidc_provider_host" {
  description = "Host do issuer OIDC do CI."
  type        = string
  default     = "token.actions.githubusercontent.com"
}

variable "ci_oidc_subjects" {
  description = "Subjects do CI autorizados a assumir a role de avaliação."
  type        = list(string)
}

# --------------------------------------------------------------- FinOps ----
variable "budget_alert_emails" {
  description = "E-mails dos alertas de orçamento."
  type        = list(string)
}

variable "enable_cur_export" {
  description = "Cria a exportação CUR 2.0."
  type        = bool
  default     = true
}

# ----------------------------------------------------------- Proteções ----
variable "deletion_protection" {
  description = "Proteção contra exclusão (ALB, NLB, firewall)."
  type        = bool
  default     = true
}

variable "force_destroy" {
  description = "Permite destruir buckets/repos com conteúdo (somente dev)."
  type        = bool
  default     = false
}
