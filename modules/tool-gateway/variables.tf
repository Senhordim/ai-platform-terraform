variable "name_prefix" {
  description = "Prefixo de nomes."
  type        = string
}

# ------------------------------------------------------------ IdP / JWT ----
variable "idp_discovery_url" {
  description = "OIDC discovery URL do IdP corporativo (Entra ID ou Okta)."
  type        = string

  validation {
    condition     = can(regex("^https://.+/\\.well-known/openid-configuration$", var.idp_discovery_url))
    error_message = "Deve ser https e terminar em /.well-known/openid-configuration."
  }
}

variable "idp_allowed_audiences" {
  description = "Audiences aceitas pelo gateway (token do operador repassado pelo agente)."
  type        = list(string)

  validation {
    condition     = length(var.idp_allowed_audiences) > 0
    error_message = "Informe ao menos uma audience."
  }
}

variable "idp_allowed_clients" {
  description = "Client IDs aceitos (opcional)."
  type        = list(string)
  default     = []
}

variable "scope_claim_name" {
  description = "Claim com os escopos no token (Okta: scp/scope; Entra ID: scp)."
  type        = string
  default     = "scope"
}

# ------------------------------------------------------- Token exchange ----
variable "token_exchange_client_id" {
  description = "Client ID registrado no IdP para o token exchange de saída."
  type        = string
}

variable "token_exchange_client_auth_method" {
  description = "Autenticação do client no token endpoint. AWS_IAM_ID_TOKEN_JWT = JWT assinado pela AWS, sem segredo."
  type        = string
  default     = "AWS_IAM_ID_TOKEN_JWT"

  validation {
    condition     = contains(["AWS_IAM_ID_TOKEN_JWT", "PRIVATE_KEY_JWT"], var.token_exchange_client_auth_method)
    error_message = "Sem chaves estáticas: use AWS_IAM_ID_TOKEN_JWT ou PRIVATE_KEY_JWT."
  }
}

variable "token_exchange_grant_type" {
  description = "TOKEN_EXCHANGE (RFC 8693, ex.: Okta) ou JWT_AUTHORIZATION_GRANT (RFC 7523/OBO, ex.: Entra ID)."
  type        = string
  default     = "TOKEN_EXCHANGE"

  validation {
    condition     = contains(["TOKEN_EXCHANGE", "JWT_AUTHORIZATION_GRANT"], var.token_exchange_grant_type)
    error_message = "Use TOKEN_EXCHANGE ou JWT_AUTHORIZATION_GRANT."
  }
}

variable "token_exchange_actor_token_content" {
  description = "Actor token (claim act) no RFC 8693: NONE, M2M ou AWS_IAM_ID_TOKEN_JWT."
  type        = string
  default     = "NONE"

  validation {
    condition     = contains(["NONE", "M2M", "AWS_IAM_ID_TOKEN_JWT"], var.token_exchange_actor_token_content)
    error_message = "Valor inválido."
  }
}

variable "enable_outbound_identity_federation" {
  description = "Habilita a outbound web identity federation da conta (false se já habilitada fora deste stack)."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------- Tools ----
variable "tools" {
  description = "Catálogo de tools (MCP) expostas pelo gateway. effect = read | write."
  type = map(object({
    description       = string
    effect            = string
    openapi_spec_path = string
    core_base_path    = string
    operations        = list(string)
    oauth_scopes      = list(string)
  }))

  validation {
    condition     = alltrue([for k, t in var.tools : contains(["read", "write"], t.effect)])
    error_message = "effect deve ser read ou write."
  }

  validation {
    condition     = alltrue([for k in keys(var.tools) : can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", k)) && length(k) <= 40])
    error_message = "Chaves de tool: minúsculas, números e hífen (até 40)."
  }

  validation {
    condition     = alltrue([for k, t in var.tools : length(t.oauth_scopes) > 0 && length(t.operations) > 0])
    error_message = "Cada tool precisa de ao menos um escopo e uma operação."
  }
}

variable "allow_write_tools" {
  description = "Permite registrar tools com efeito (write). Falso no piloto."
  type        = bool
  default     = false
}

variable "policy_enforcement_mode" {
  description = "Modo do Policy in AgentCore: LOG_ONLY (dev) ou ENFORCE (prd)."
  type        = string
  default     = "ENFORCE"

  validation {
    condition     = contains(["LOG_ONLY", "ENFORCE"], var.policy_enforcement_mode)
    error_message = "Use LOG_ONLY ou ENFORCE."
  }
}

variable "policy_validation_mode" {
  description = "Validação das policies Cedar: FAIL_ON_ANY_FINDINGS ou IGNORE_ALL_FINDINGS."
  type        = string
  default     = "FAIL_ON_ANY_FINDINGS"

  validation {
    condition     = contains(["FAIL_ON_ANY_FINDINGS", "IGNORE_ALL_FINDINGS"], var.policy_validation_mode)
    error_message = "Valor inválido."
  }
}

# ------------------------------------------------------------- Rede/core ----
variable "vpc_id" {
  description = "VPC da plataforma."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets privadas (Lattice ENIs do gateway e NLB)."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group das ENIs do Lattice."
  type        = string
}

variable "execute_api_vpce_id" {
  description = "VPC endpoint execute-api (resource policy do API privado)."
  type        = string
}

variable "execute_api_vpce_dns_name" {
  description = "DNS regional do VPC endpoint execute-api (routing_domain)."
  type        = string
}

variable "core_api_hostname" {
  description = "Hostname TLS das APIs do core (CN/SAN do certificado do backend)."
  type        = string
}

variable "core_target_ips" {
  description = "IPs das APIs do core no data center (alcançados via Direct Connect)."
  type        = list(string)

  validation {
    condition     = alltrue([for ip in var.core_target_ips : can(cidrhost("${ip}/32", 0))])
    error_message = "Informe IPs IPv4 válidos."
  }
}

variable "core_api_stage_name" {
  description = "Nome do stage do API privado."
  type        = string
  default     = "v1"
}

variable "core_api_throttle_rate" {
  description = "Throttling (req/s) do API privado."
  type        = number
  default     = 50
}

variable "core_api_throttle_burst" {
  description = "Burst do API privado."
  type        = number
  default     = 100
}

variable "manage_apigw_account_settings" {
  description = "Gerencia a role de CloudWatch da conta do API Gateway (singleton por região)."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------- Comum ----
variable "data_kms_key_arn" {
  description = "CMK de dados (gateway, policy engine)."
  type        = string
}

variable "logs_kms_key_arn" {
  description = "CMK de logs."
  type        = string
}

variable "log_retention_days" {
  description = "Retenção de logs (dias)."
  type        = number
}

variable "deletion_protection" {
  description = "Proteção contra exclusão (NLB)."
  type        = bool
  default     = true
}
