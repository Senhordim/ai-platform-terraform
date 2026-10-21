# Entrada: ALB INTERNO (alcançável apenas pela rede corporativa via Direct
# Connect) com listener HTTPS e ação authenticate-oidc no IdP corporativo,
# protegido por AWS WAF (managed rule groups).
#
# Fluxo: operador -> ALB (login OIDC) -> aplicação da central (target group,
# BFF publicado pelo time da aplicação) -> InvokeAgentRuntime no endpoint do
# AgentCore Runtime (VPCE bedrock-agentcore) com o access token do operador
# (header x-amzn-oidc-accesstoken repassado pelo ALB) e o ID do caso de uso.
#
# Exceção documentada a "sem chaves estáticas": authenticate-oidc exige o
# client secret do IdP. Ele é lido do Secrets Manager (pré-criado pelo time
# de identidade) e fica no state — que é criptografado com KMS no S3.

data "aws_secretsmanager_secret_version" "oidc_client_secret" {
  secret_id = var.oidc_client_secret_arn
}

data "aws_elb_service_account" "this" {}
data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
}

# --------------------------------------------------------- Access logs ----
module "alb_logs_bucket" {
  source = "../s3-secure-bucket"

  name                   = "${var.bucket_prefix}-alb-logs"
  kms_key_arn            = null # ALB access logs exigem SSE-S3.
  access_log_bucket      = var.access_log_bucket
  expiration_days        = var.alb_logs_expiration_days
  force_destroy          = var.force_destroy
  additional_policy_json = data.aws_iam_policy_document.alb_logs.json
}

data "aws_iam_policy_document" "alb_logs" {
  statement {
    sid       = "ElbLogDelivery"
    actions   = ["s3:PutObject"]
    resources = ["arn:${local.partition}:s3:::${var.bucket_prefix}-alb-logs/AWSLogs/${local.account_id}/*"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.this.arn]
    }
  }
}

# ---------------------------------------------------------------- ALB ----
resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "ALB interno da plataforma de agentes"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = toset(var.allowed_client_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS da rede corporativa"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "alb_to_targets" {
  security_group_id = aws_security_group.alb.id
  description       = "Para os targets na VPC"
  ip_protocol       = "tcp"
  from_port         = var.target_port
  to_port           = var.target_port
  cidr_ipv4         = var.vpc_cidr
}

# authenticate-oidc: os nós do ALB chamam o token/userinfo endpoint do IdP.
# - IdP alcançável por rota privada (DX/proxy): informe idp_egress_cidrs.
# - IdP SaaS (Entra ID / Okta): habilite idp_egress_via_firewall e inclua os
#   domínios do IdP em egress_allowed_domains (módulo network). A saída
#   0.0.0.0/0:443 do SG é restringida por domínio no Network Firewall.
resource "aws_vpc_security_group_egress_rule" "alb_to_idp" {
  for_each = toset(var.idp_egress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS para o IdP (rota privada)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "alb_to_idp_via_firewall" {
  #checkov:skip=CKV_AWS_382:Saída 443 filtrada por domínio (allowlist do IdP) no AWS Network Firewall.
  count = var.idp_egress_via_firewall ? 1 : 0

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS para o IdP SaaS, filtrado por domínio no Network Firewall"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_lb" "this" {
  name                       = substr("${var.name_prefix}-ingress", 0, 32)
  internal                   = true
  load_balancer_type         = "application"
  subnets                    = var.subnet_ids
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
  enable_deletion_protection = var.deletion_protection
  desync_mitigation_mode     = "strictest"

  access_logs {
    bucket  = module.alb_logs_bucket.id
    enabled = true
  }

  depends_on = [module.alb_logs_bucket]
}

resource "aws_lb_target_group" "app" {
  name        = substr("${var.name_prefix}-app", 0, 32)
  port        = var.target_port
  protocol    = "HTTPS"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    protocol = "HTTPS"
    path     = var.health_check_path
    matcher  = "200-399"
  }
}

resource "aws_lb_target_group_attachment" "app" {
  for_each = toset(var.target_ips)

  target_group_arn = aws_lb_target_group.app.arn
  target_id        = each.value
  port             = var.target_port
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type  = "authenticate-oidc"
    order = 1

    authenticate_oidc {
      issuer                     = var.oidc.issuer
      authorization_endpoint     = var.oidc.authorization_endpoint
      token_endpoint             = var.oidc.token_endpoint
      user_info_endpoint         = var.oidc.user_info_endpoint
      client_id                  = var.oidc.client_id
      client_secret              = data.aws_secretsmanager_secret_version.oidc_client_secret.secret_string
      scope                      = var.oidc.scope
      session_timeout            = var.oidc_session_timeout_seconds
      on_unauthenticated_request = "authenticate"
    }
  }

  default_action {
    type             = "forward"
    order            = 2
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ---------------------------------------------------------------- WAF ----
locals {
  managed_rule_groups = {
    AWSManagedRulesCommonRuleSet          = 10
    AWSManagedRulesKnownBadInputsRuleSet  = 20
    AWSManagedRulesAmazonIpReputationList = 30
    AWSManagedRulesSQLiRuleSet            = 40
    AWSManagedRulesAnonymousIpList        = 50
  }
}

resource "aws_wafv2_web_acl" "this" {
  #checkov:skip=CKV_AWS_192:AWSManagedRulesKnownBadInputsRuleSet (Log4j) está incluído via bloco dynamic, que o checkov não avalia.
  name        = "${var.name_prefix}-ingress"
  description = "WAF do ALB interno da plataforma de agentes"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = local.managed_rule_groups
    content {
      name     = rule.key
      priority = rule.value

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.key
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 100

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit_per_5min
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-per-ip"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-ingress"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.this.arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}

resource "aws_cloudwatch_log_group" "waf" {
  # O nome precisa começar com aws-waf-logs-.
  name              = "aws-waf-logs-${var.name_prefix}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  resource_arn            = aws_wafv2_web_acl.this.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
}
