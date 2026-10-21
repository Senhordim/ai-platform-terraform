variable "name_prefix" {
  description = "Prefixo de nomes (ex.: aip-dev)."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR /16 da VPC (não pode sobrepor o data center)."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && endswith(var.vpc_cidr, "/16")
    error_message = "vpc_cidr deve ser um CIDR /16 válido."
  }
}

variable "az_count" {
  description = "Número de AZs (mínimo 2)."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count deve ser 2 ou 3."
  }
}

variable "availability_zone_ids" {
  description = "AZ IDs usados (fixos por ID, não por nome)."
  type        = list(string)
  default     = ["sae1-az1", "sae1-az2", "sae1-az3"]

  validation {
    condition     = alltrue([for z in var.availability_zone_ids : can(regex("^sae1-az[0-9]+$", z))])
    error_message = "Use AZ IDs de sa-east-1 (sae1-azN)."
  }
}

variable "interface_endpoint_services" {
  description = "Serviços com VPC endpoint de interface (sufixo após com.amazonaws.<região>.)."
  type        = list(string)
  default = [
    "bedrock",
    "bedrock-runtime",
    "bedrock-agent",
    "bedrock-agent-runtime",
    "bedrock-agentcore",
    "sts",
    "logs",
    "kms",
    "secretsmanager",
    "ssm",
    "ecr.api",
    "ecr.dkr",
    "execute-api",
  ]
}

variable "additional_interface_endpoint_services" {
  description = "Endpoints extras (ex.: bedrock-agentcore.gateway, xray, monitoring) — confirme disponibilidade em sa-east-1."
  type        = list(string)
  default     = []
}

variable "egress_allowed_domains" {
  description = "Allowlist de domínios para egress externo via Network Firewall (ex.: \".pypi.org\"). Vazia = nenhum egress externo e nenhum NAT/IGW/firewall criado."
  type        = list(string)
  default     = []
}

variable "transit_gateway_id" {
  description = "ID do Transit Gateway compartilhado (RAM) que alcança o data center via Direct Connect. null = sem attachment."
  type        = string
  default     = null
}

variable "onprem_cidrs" {
  description = "CIDRs do data center (APIs do core) roteados via TGW/Direct Connect."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.onprem_cidrs : can(cidrhost(c, 0))])
    error_message = "onprem_cidrs deve conter CIDRs válidos."
  }
}

variable "logs_kms_key_arn" {
  description = "CMK de logs."
  type        = string
}

variable "data_kms_key_arn" {
  description = "CMK de dados (Network Firewall)."
  type        = string
}

variable "log_retention_days" {
  description = "Retenção dos logs (dias)."
  type        = number
}

variable "deletion_protection" {
  description = "Proteção contra exclusão (firewall)."
  type        = bool
  default     = true
}
