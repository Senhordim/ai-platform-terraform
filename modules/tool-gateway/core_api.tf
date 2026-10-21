# API Gateway REST PRIVADO na frente das APIs do core (data center, via
# Direct Connect). Só é invocável pelo VPC endpoint execute-api desta VPC
# (resource policy) e só expõe métodos GET (tools somente leitura).
#
# Caminho: AgentCore Gateway -> Lattice -> VPCE execute-api -> API privado
#          -> VPC Link -> NLB interno -> IPs do core (TGW/Direct Connect).
#
# mTLS: a API Gateway não suporta mTLS de ENTRADA em endpoints PRIVATE
# (truststore só existe em custom domain regional). Alternativa adotada:
#  (1) entrada restrita ao VPC endpoint por resource policy + token do
#      operador validado pelo core;
#  (2) mTLS de SAÍDA: o stage apresenta um client certificate do API Gateway
#      ao backend, que deve exigi-lo (o NLB faz TCP passthrough até o core).
# TODO(validar): suporte a client certificate em integração VPC_LINK com NLB
# TCP passthrough; se não houver, terminar TLS num proxy do lado do core.

resource "aws_lb" "core" {
  #checkov:skip=CKV_AWS_91:NLB TCP passthrough não gera access logs (só listeners TLS); fluxos ficam nos VPC Flow Logs.
  #checkov:skip=CKV2_AWS_20:Listener TCP 443 em passthrough; o TLS é fim a fim até o core.
  #checkov:skip=CKV2_AWS_28:NLB interno sem exposição HTTP; WAF não se aplica a NLB.
  name                             = substr("${var.name_prefix}-core-nlb", 0, 32)
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = var.subnet_ids
  enable_deletion_protection       = var.deletion_protection
  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "core" {
  name        = substr("${var.name_prefix}-core-tg", 0, 32)
  port        = 443
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    protocol = "TCP"
    port     = "443"
  }
}

# IPs do core fora da VPC (alcançados via TGW/Direct Connect).
resource "aws_lb_target_group_attachment" "core" {
  for_each = toset(var.core_target_ips)

  target_group_arn  = aws_lb_target_group.core.arn
  target_id         = each.value
  port              = 443
  availability_zone = "all"
}

resource "aws_lb_listener" "core" {
  #checkov:skip=CKV_AWS_2:Listener TCP (passthrough) — o TLS é negociado entre API Gateway e o core.
  #checkov:skip=CKV_AWS_103:Listener TCP (passthrough) — sem terminação TLS no NLB.
  load_balancer_arn = aws_lb.core.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.core.arn
  }
}

resource "aws_api_gateway_vpc_link" "core" {
  name        = "${var.name_prefix}-core"
  description = "VPC Link para o NLB das APIs do core"
  target_arns = [aws_lb.core.arn]
}

# --------------------------------------------------------- REST API ----
resource "aws_api_gateway_rest_api" "core" {
  name        = "${var.name_prefix}-core-private"
  description = "Fachada privada (somente leitura) das APIs do core para o AgentCore Gateway"

  endpoint_configuration {
    types            = ["PRIVATE"]
    vpc_endpoint_ids = [var.execute_api_vpce_id]
  }

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_iam_policy_document" "core_api" {
  statement {
    sid       = "AllowGetFromPlatformVpce"
    effect    = "Allow"
    actions   = ["execute-api:Invoke"]
    resources = ["${aws_api_gateway_rest_api.core.execution_arn}/*/GET/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpce"
      values   = [var.execute_api_vpce_id]
    }
  }

  statement {
    sid       = "DenyOutsidePlatformVpce"
    effect    = "Deny"
    actions   = ["execute-api:Invoke"]
    resources = ["${aws_api_gateway_rest_api.core.execution_arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "aws:SourceVpce"
      values   = [var.execute_api_vpce_id]
    }
  }
}

resource "aws_api_gateway_rest_api_policy" "core" {
  rest_api_id = aws_api_gateway_rest_api.core.id
  policy      = data.aws_iam_policy_document.core_api.json
}

# /<base_path>/{proxy+}  GET -> https://<core_host>/<base_path>/{proxy}
resource "aws_api_gateway_resource" "base" {
  for_each = var.tools

  rest_api_id = aws_api_gateway_rest_api.core.id
  parent_id   = aws_api_gateway_rest_api.core.root_resource_id
  path_part   = each.value.core_base_path
}

resource "aws_api_gateway_resource" "proxy" {
  for_each = var.tools

  rest_api_id = aws_api_gateway_rest_api.core.id
  parent_id   = aws_api_gateway_resource.base[each.key].id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "get" {
  #checkov:skip=CKV_AWS_59:API PRIVATE restrita ao VPCE por resource policy; o core valida o token do operador obtido por token exchange (RFC 8693).
  #checkov:skip=CKV2_AWS_53:Validação de request feita pelo esquema OpenAPI no AgentCore Gateway e pelo core.
  for_each = var.tools

  rest_api_id   = aws_api_gateway_rest_api.core.id
  resource_id   = aws_api_gateway_resource.proxy[each.key].id
  http_method   = "GET"
  authorization = "NONE"

  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_integration" "get" {
  for_each = var.tools

  rest_api_id             = aws_api_gateway_rest_api.core.id
  resource_id             = aws_api_gateway_resource.proxy[each.key].id
  http_method             = aws_api_gateway_method.get[each.key].http_method
  type                    = "HTTP_PROXY"
  integration_http_method = "GET"
  uri                     = "https://${var.core_api_hostname}/${each.value.core_base_path}/{proxy}"
  connection_type         = "VPC_LINK"
  connection_id           = aws_api_gateway_vpc_link.core.id
  timeout_milliseconds    = 10000

  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }

  tls_config {
    insecure_skip_verification = false
  }
}

resource "aws_api_gateway_deployment" "core" {
  rest_api_id = aws_api_gateway_rest_api.core.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.base,
      aws_api_gateway_resource.proxy,
      aws_api_gateway_method.get,
      aws_api_gateway_integration.get,
      aws_api_gateway_rest_api_policy.core.policy,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_client_certificate" "core" {
  description = "Certificado cliente apresentado ao core (mTLS de saída)"
}

resource "aws_cloudwatch_log_group" "core_api" {
  name              = "/aws/apigateway/${var.name_prefix}-core-private/access"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
}

resource "aws_api_gateway_stage" "core" {
  #checkov:skip=CKV2_AWS_51:mTLS de entrada não é suportado em APIs PRIVATE; ver alternativa no topo do arquivo.
  #checkov:skip=CKV_AWS_120:Cache desabilitado de propósito — dados transacionais (PIX, limites) não podem ser servidos de cache.
  #checkov:skip=CKV2_AWS_29:WAF não se associa a APIs PRIVATE; acesso restrito ao VPCE por resource policy.
  rest_api_id           = aws_api_gateway_rest_api.core.id
  deployment_id         = aws_api_gateway_deployment.core.id
  stage_name            = var.core_api_stage_name
  xray_tracing_enabled  = true
  client_certificate_id = aws_api_gateway_client_certificate.core.id

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.core_api.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      sourceVpce     = "$context.identity.vpceId"
      httpMethod     = "$context.httpMethod"
      resourcePath   = "$context.resourcePath"
      status         = "$context.status"
      latency        = "$context.responseLatency"
      integrationErr = "$context.integration.error"
      requestTime    = "$context.requestTime"
    })
  }

  depends_on = [aws_api_gateway_account.this]
}

resource "aws_api_gateway_method_settings" "all" {
  #checkov:skip=CKV_AWS_225:Cache desabilitado de propósito — dados transacionais (PIX, limites) não podem ser servidos de cache.
  rest_api_id = aws_api_gateway_rest_api.core.id
  stage_name  = aws_api_gateway_stage.core.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled        = true
    logging_level          = "ERROR"
    data_trace_enabled     = false
    caching_enabled        = false
    throttling_rate_limit  = var.core_api_throttle_rate
    throttling_burst_limit = var.core_api_throttle_burst
  }
}

# Configuração de conta do API Gateway (role para CloudWatch Logs). Recurso
# único por conta/região — desligue se já for gerenciado em outro stack.
data "aws_iam_policy_document" "apigw_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw_cloudwatch" {
  count              = var.manage_apigw_account_settings ? 1 : 0
  name               = "${var.name_prefix}-apigw-cloudwatch"
  assume_role_policy = data.aws_iam_policy_document.apigw_assume.json
}

resource "aws_iam_role_policy_attachment" "apigw_cloudwatch" {
  count      = var.manage_apigw_account_settings ? 1 : 0
  role       = aws_iam_role.apigw_cloudwatch[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "this" {
  count               = var.manage_apigw_account_settings ? 1 : 0
  cloudwatch_role_arn = aws_iam_role.apigw_cloudwatch[0].arn

  depends_on = [aws_iam_role_policy_attachment.apigw_cloudwatch]
}
