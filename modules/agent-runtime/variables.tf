variable "name_prefix" {
  description = "Prefixo de nomes."
  type        = string
}

variable "environment" {
  description = "Ambiente (dev, prd)."
  type        = string
}

variable "use_case" {
  description = "ID do caso de uso."
  type        = string
}

variable "role_arn" {
  description = "Role de execução (role do caso de uso)."
  type        = string
}

variable "role_name" {
  description = "Nome da role de execução (recebe a policy do runtime)."
  type        = string
}

variable "container_image_tag" {
  description = "Tag imutável da imagem do agente no ECR (publicada pelo pipeline)."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets privadas de workload."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group do runtime."
  type        = string
}

variable "idp_discovery_url" {
  description = "OIDC discovery URL do IdP corporativo."
  type        = string

  validation {
    condition     = can(regex("^https://.+/\\.well-known/openid-configuration$", var.idp_discovery_url))
    error_message = "Deve ser https e terminar em /.well-known/openid-configuration."
  }
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

variable "inference_profile_arns" {
  description = "Profiles do caso (model_id => ARN), entregues ao agente por variável de ambiente."
  type        = map(string)
}

variable "guardrail" {
  description = "Guardrail do caso."
  type = object({
    id      = string
    arn     = string
    version = string
  })
}

variable "gateway_url" {
  description = "URL MCP do AgentCore Gateway."
  type        = string
}

variable "knowledge_base_id" {
  description = "ID da knowledge base (null = sem RAG)."
  type        = string
  default     = null
}

variable "idle_session_timeout_seconds" {
  description = "Timeout de sessão ociosa (s)."
  type        = number
  default     = 900
}

variable "max_session_lifetime_seconds" {
  description = "Duração máxima de sessão (s)."
  type        = number
  default     = 28800
}

variable "extra_environment_variables" {
  description = "Variáveis de ambiente adicionais (sem segredos)."
  type        = map(string)
  default     = {}
}

variable "data_kms_key_arn" {
  description = "CMK de dados (ECR)."
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

variable "force_destroy" {
  description = "Permite apagar o repositório com imagens (somente dev)."
  type        = bool
  default     = false
}
