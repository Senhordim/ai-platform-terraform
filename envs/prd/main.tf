# Composição da conta de workload "AI Platform".
# Ordem lógica: kms -> network -> observability -> llm-gateway ->
# knowledge-base -> tool-gateway -> use-case -> agent-runtime ->
# evaluation -> finops -> ingress -> security-baseline.

data "aws_caller_identity" "current" {}

locals {
  name_prefix   = "aip-${var.environment}"
  bucket_prefix = "${var.bucket_namespace}-aip-${var.environment}-${data.aws_caller_identity.current.account_id}"
}

# ------------------------------------------- Checagens do registro ----
# Falham o plan se um caso de uso pedir modelo/tool fora do catálogo.
resource "terraform_data" "registry_checks" {
  input = keys(var.use_cases)

  lifecycle {
    precondition {
      condition = alltrue(flatten([
        for k, uc in var.use_cases : [for m in uc.allowed_models : contains(var.allowed_model_ids, m)]
      ]))
      error_message = "Todo modelo em use_cases[*].allowed_models precisa estar em allowed_model_ids."
    }

    precondition {
      condition = alltrue(flatten([
        for k, uc in var.use_cases : [for t in uc.allowed_tools : contains(keys(var.tools), t)]
      ]))
      error_message = "Toda tool em use_cases[*].allowed_tools precisa existir em tools."
    }

    precondition {
      condition     = contains(var.allowed_model_ids, var.embedding_model_id)
      error_message = "embedding_model_id precisa estar em allowed_model_ids (a SCP nega modelos fora da allowlist)."
    }

    precondition {
      condition     = var.environment == "prd" && var.policy_enforcement_mode == "ENFORCE" && !var.force_destroy && var.deletion_protection && var.cloudtrail_object_lock_mode == "COMPLIANCE"
      error_message = "Em prd: environment=prd, Policy em ENFORCE, force_destroy=false, deletion_protection=true e Object Lock COMPLIANCE."
    }

    precondition {
      condition     = !var.alb_idp_egress_via_firewall || length(var.egress_allowed_domains) > 0
      error_message = "alb_idp_egress_via_firewall exige os domínios do IdP em egress_allowed_domains."
    }
  }
}

# ------------------------------------------------------------- KMS ----
module "kms" {
  source = "../../modules/kms"

  name_prefix         = local.name_prefix
  key_admin_role_arns = var.key_admin_role_arns
}

# ------------------------------------------------------------ Rede ----
module "network" {
  source = "../../modules/network"

  name_prefix                            = local.name_prefix
  vpc_cidr                               = var.vpc_cidr
  transit_gateway_id                     = var.transit_gateway_id
  onprem_cidrs                           = var.onprem_cidrs
  egress_allowed_domains                 = var.egress_allowed_domains
  additional_interface_endpoint_services = var.additional_interface_endpoint_services
  logs_kms_key_arn                       = module.kms.logs_key_arn
  data_kms_key_arn                       = module.kms.data_key_arn
  log_retention_days                     = var.log_retention_days
  deletion_protection                    = var.deletion_protection
}

# ------------------------------------------------- Observabilidade ⑤ ----
module "observability" {
  source = "../../modules/observability"

  name_prefix                 = local.name_prefix
  bucket_prefix               = local.bucket_prefix
  logs_kms_key_arn            = module.kms.logs_key_arn
  log_retention_days          = var.log_retention_days
  cloudtrail_object_lock_mode = var.cloudtrail_object_lock_mode
  cloudtrail_object_lock_days = var.cloudtrail_object_lock_days
  cloudtrail_data_event_bucket_arns = [
    module.knowledge_base.documents_bucket_arn,
    module.evaluation.bucket_arn,
  ]
  siem_destination_arn = var.siem_destination_arn
  siem_log_group_names = merge(
    {
      bedrock-invocations = module.llm_gateway.invocation_log_group_name
      agentcore-gateway   = module.tool_gateway.gateway_log_group_name
      core-api            = module.tool_gateway.core_api_log_group_name
      waf                 = module.ingress.waf_log_group_name
    },
    { for k, r in module.agent_runtime : "runtime-${k}" => r.log_group_name },
  )
  force_destroy = var.force_destroy
}

# ------------------------------------------------- LLM Gateway ① ----
module "llm_gateway" {
  source = "../../modules/llm-gateway"

  name_prefix        = local.name_prefix
  bucket_prefix      = local.bucket_prefix
  use_cases          = { for k, uc in var.use_cases : k => { risk_classification = uc.risk_classification } }
  allowed_model_ids  = var.allowed_model_ids
  denied_topics      = var.denied_topics
  data_kms_key_arn   = module.kms.data_key_arn
  logs_kms_key_arn   = module.kms.logs_key_arn
  access_log_bucket  = module.observability.access_log_bucket
  log_retention_days = var.log_retention_days
  force_destroy      = var.force_destroy
}

# ------------------------------------------------ Conhecimento ④ ----
module "knowledge_base" {
  source = "../../modules/knowledge-base"

  name_prefix               = local.name_prefix
  bucket_prefix             = local.bucket_prefix
  vpc_id                    = module.network.vpc_id
  subnet_ids                = module.network.endpoint_subnet_ids
  security_group_id         = module.network.endpoints_security_group_id
  embedding_model_id        = var.embedding_model_id
  embedding_dimensions      = var.embedding_dimensions
  standby_replicas          = var.aoss_standby_replicas
  aoss_admin_principal_arns = var.platform_admin_role_arns
  kb_kms_key_arn            = module.kms.kb_key_arn
  access_log_bucket         = module.observability.access_log_bucket
  force_destroy             = var.force_destroy
}

# ------------------------------------------------ Tool Gateway ② ----
module "tool_gateway" {
  source = "../../modules/tool-gateway"

  name_prefix                         = local.name_prefix
  idp_discovery_url                   = var.idp_discovery_url
  idp_allowed_audiences               = var.idp_allowed_audiences
  idp_allowed_clients                 = var.idp_allowed_clients
  scope_claim_name                    = var.idp_scope_claim_name
  token_exchange_client_id            = var.token_exchange_client_id
  token_exchange_grant_type           = var.token_exchange_grant_type
  enable_outbound_identity_federation = var.enable_outbound_identity_federation
  tools                               = var.tools
  allow_write_tools                   = false
  policy_enforcement_mode             = var.policy_enforcement_mode
  vpc_id                              = module.network.vpc_id
  subnet_ids                          = module.network.workload_subnet_ids
  security_group_id                   = module.network.workload_security_group_id
  execute_api_vpce_id                 = module.network.execute_api_vpce_id
  execute_api_vpce_dns_name           = module.network.execute_api_vpce_dns_name
  core_api_hostname                   = var.core_api_hostname
  core_target_ips                     = var.core_target_ips
  manage_apigw_account_settings       = var.manage_apigw_account_settings
  data_kms_key_arn                    = module.kms.data_key_arn
  logs_kms_key_arn                    = module.kms.logs_key_arn
  log_retention_days                  = var.log_retention_days
  deletion_protection                 = var.deletion_protection
}

# ------------------------------------------- Registro de casos ③ ----
module "use_case" {
  source   = "../../modules/use-case"
  for_each = var.use_cases

  name_prefix        = local.name_prefix
  name               = each.key
  config             = each.value
  guardrail          = module.llm_gateway.guardrails[each.key]
  knowledge_base_arn = module.knowledge_base.knowledge_base_arn
}

# ------------------------------------------- Agentes (AgentCore) ----
module "agent_runtime" {
  source   = "../../modules/agent-runtime"
  for_each = var.use_cases

  name_prefix            = local.name_prefix
  environment            = var.environment
  use_case               = each.key
  role_arn               = module.use_case[each.key].role_arn
  role_name              = module.use_case[each.key].role_name
  container_image_tag    = each.value.container_image_tag
  subnet_ids             = module.network.workload_subnet_ids
  security_group_id      = module.network.workload_security_group_id
  idp_discovery_url      = var.idp_discovery_url
  idp_allowed_audiences  = var.idp_allowed_audiences
  idp_allowed_clients    = var.idp_allowed_clients
  inference_profile_arns = module.use_case[each.key].inference_profile_arns
  guardrail              = module.llm_gateway.guardrails[each.key]
  gateway_url            = module.tool_gateway.gateway_url
  knowledge_base_id      = each.value.knowledge_base_access ? module.knowledge_base.knowledge_base_id : null
  data_kms_key_arn       = module.kms.data_key_arn
  logs_kms_key_arn       = module.kms.logs_key_arn
  log_retention_days     = var.log_retention_days
  force_destroy          = var.force_destroy
}

# ------------------------------------------------------ Avaliação ⑥ ----
module "evaluation" {
  source = "../../modules/evaluation"

  name_prefix           = local.name_prefix
  bucket_prefix         = local.bucket_prefix
  use_case_names        = keys(var.use_cases)
  agent_runtime_arns    = [for r in module.agent_runtime : r.agent_runtime_arn]
  ci_oidc_provider_arn  = var.ci_oidc_provider_arn
  ci_oidc_provider_host = var.ci_oidc_provider_host
  ci_oidc_subjects      = var.ci_oidc_subjects
  data_kms_key_arn      = module.kms.data_key_arn
  access_log_bucket     = module.observability.access_log_bucket
  force_destroy         = var.force_destroy
}

# ---------------------------------------------------------- FinOps ----
module "finops" {
  source = "../../modules/finops"

  name_prefix   = local.name_prefix
  bucket_prefix = local.bucket_prefix
  use_cases = {
    for k, uc in var.use_cases : k => {
      monthly_budget_usd = uc.monthly_budget_usd
      role_arn           = module.use_case[k].role_arn
      role_name          = module.use_case[k].role_name
      block_policy_arn   = module.use_case[k].budget_block_policy_arn
    }
  }
  budget_alert_emails = var.budget_alert_emails
  enable_cur_export   = var.enable_cur_export
  data_kms_key_arn    = module.kms.data_key_arn
  access_log_bucket   = module.observability.access_log_bucket
  force_destroy       = var.force_destroy
}

# --------------------------------------------------------- Entrada ----
module "ingress" {
  source = "../../modules/ingress"

  name_prefix             = local.name_prefix
  bucket_prefix           = local.bucket_prefix
  vpc_id                  = module.network.vpc_id
  vpc_cidr                = module.network.vpc_cidr
  subnet_ids              = module.network.workload_subnet_ids
  allowed_client_cidrs    = var.alb_allowed_client_cidrs
  idp_egress_cidrs        = var.alb_idp_egress_cidrs
  idp_egress_via_firewall = var.alb_idp_egress_via_firewall
  certificate_arn         = var.alb_certificate_arn
  oidc                    = var.alb_oidc
  oidc_client_secret_arn  = var.alb_oidc_client_secret_arn
  target_ips              = var.alb_target_ips
  logs_kms_key_arn        = module.kms.logs_key_arn
  log_retention_days      = var.log_retention_days
  access_log_bucket       = module.observability.access_log_bucket
  deletion_protection     = var.deletion_protection
  force_destroy           = var.force_destroy
}

# ------------------------------------------------ Baseline de conta ----
module "security_baseline" {
  source = "../../modules/security-baseline"

  name_prefix                       = local.name_prefix
  bucket_prefix                     = local.bucket_prefix
  logs_kms_key_arn                  = module.kms.logs_key_arn
  access_log_bucket                 = module.observability.access_log_bucket
  enable_config                     = var.enable_config
  create_config_service_linked_role = var.create_config_service_linked_role
  enable_guardduty                  = var.enable_guardduty
  enable_macie                      = var.enable_macie
  macie_bucket_names                = [module.knowledge_base.documents_bucket]
  force_destroy                     = var.force_destroy
}
