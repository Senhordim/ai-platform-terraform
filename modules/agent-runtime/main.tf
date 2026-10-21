# Agente do caso de uso no Bedrock AgentCore Runtime (rede VPC, sem
# internet), com:
# - autorização de entrada via JWT do IdP corporativo (o token do operador
#   chega no header Authorization e é repassado ao agente);
# - workload identity própria (AgentCore Identity);
# - AgentCore Observability: logs de aplicação -> CloudWatch Logs e traces ->
#   X-Ray (Transaction Search habilitado no módulo observability), ADOT no
#   container via variáveis de ambiente.
# A role de execução é a role de menor privilégio do caso de uso
# (módulo use-case); aqui só somamos o necessário para o runtime operar.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  # Nomes de runtime/endpoint: [a-zA-Z][a-zA-Z0-9_]{0,47}
  runtime_name = substr(replace("${var.name_prefix}_${var.use_case}", "-", "_"), 0, 48)

  workload_identity_arn = "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:workload-identity-directory/default/workload-identity/${aws_bedrockagentcore_workload_identity.this.name}"
}

# ---------------------------------------------------------- Imagem (ECR) ----
resource "aws_ecr_repository" "this" {
  name                 = "${var.name_prefix}/agents/${var.use_case}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.force_destroy

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.data_kms_key_arn
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Mantém as últimas 30 imagens"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}

# ------------------------------------------------------ AgentCore Identity --
resource "aws_bedrockagentcore_workload_identity" "this" {
  name = "${var.name_prefix}-${var.use_case}"
  tags = { use_case = var.use_case }
}

# ------------------------------------------------- Permissões do runtime ----
data "aws_iam_policy_document" "runtime" {
  statement {
    sid       = "PullOwnImage"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = [aws_ecr_repository.this.arn]
  }

  statement {
    sid       = "EcrAuthToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # GetAuthorizationToken não suporta resource-level permissions.
  }

  statement {
    sid = "RuntimeLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*",
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*",
    ]
  }

  statement {
    sid = "XRayTracing"
    actions = [
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
      "xray:PutTelemetryRecords",
      "xray:PutTraceSegments",
    ]
    resources = ["*"] # X-Ray não suporta resource-level permissions para estas ações.
  }

  statement {
    sid       = "AgentCoreMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"] # PutMetricData não suporta resource-level; restrito por namespace.
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["bedrock-agentcore"]
    }
  }

  statement {
    sid = "WorkloadAccessToken"
    actions = [
      "bedrock-agentcore:GetWorkloadAccessToken",
      "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
    ]
    resources = [
      "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:workload-identity-directory/default",
      local.workload_identity_arn,
    ]
  }
}

resource "aws_iam_role_policy" "runtime" {
  name   = "agentcore-runtime"
  role   = var.role_name
  policy = data.aws_iam_policy_document.runtime.json
}

# --------------------------------------------------------------- Runtime ----
resource "aws_bedrockagentcore_agent_runtime" "this" {
  agent_runtime_name = local.runtime_name
  description        = "Agente do caso de uso ${var.use_case}"
  role_arn           = var.role_arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = "${aws_ecr_repository.this.repository_url}:${var.container_image_tag}"
    }
  }

  network_configuration {
    network_mode = "VPC"
    network_mode_config {
      subnets         = var.subnet_ids
      security_groups = [var.security_group_id]
    }
  }

  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url    = var.idp_discovery_url
      allowed_audience = var.idp_allowed_audiences
      allowed_clients  = length(var.idp_allowed_clients) > 0 ? var.idp_allowed_clients : null
    }
  }

  protocol_configuration {
    server_protocol = "HTTP"
  }

  request_header_configuration {
    # Authorization: token do operador, usado pelo agente para chamar o
    # AgentCore Gateway em nome do usuário. O header custom carrega o ID do
    # caso de uso enviado pela aplicação da central.
    request_header_allowlist = [
      "Authorization",
      "X-Amzn-Bedrock-AgentCore-Runtime-Custom-Use-Case-Id",
    ]
  }

  lifecycle_configuration {
    idle_runtime_session_timeout = var.idle_session_timeout_seconds
    max_lifetime                 = var.max_session_lifetime_seconds
  }

  environment_variables = merge(
    {
      USE_CASE_ID                    = var.use_case
      BEDROCK_INFERENCE_PROFILE_ARNS = jsonencode(var.inference_profile_arns)
      BEDROCK_GUARDRAIL_ID           = var.guardrail.id
      BEDROCK_GUARDRAIL_VERSION      = var.guardrail.version
      AGENTCORE_GATEWAY_URL          = var.gateway_url
      KNOWLEDGE_BASE_ID              = coalesce(var.knowledge_base_id, "none")
      WORKLOAD_IDENTITY_NAME         = aws_bedrockagentcore_workload_identity.this.name
      HUMAN_IN_THE_LOOP              = "required"
      TOOLS_MODE                     = "read-only"

      # AgentCore Observability (ADOT)
      AGENT_OBSERVABILITY_ENABLED = "true"
      OTEL_PYTHON_DISTRO          = "aws_distro"
      OTEL_PYTHON_CONFIGURATOR    = "aws_configurator"
      OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf"
      OTEL_RESOURCE_ATTRIBUTES    = "service.name=${local.runtime_name},deployment.environment=${var.environment}"
    },
    var.extra_environment_variables,
  )

  tags = { use_case = var.use_case }

  depends_on = [aws_iam_role_policy.runtime]
}

resource "aws_bedrockagentcore_agent_runtime_endpoint" "this" {
  name                  = "${local.runtime_name}_live"
  agent_runtime_id      = aws_bedrockagentcore_agent_runtime.this.agent_runtime_id
  agent_runtime_version = aws_bedrockagentcore_agent_runtime.this.agent_runtime_version
  description           = "Endpoint estável usado pela aplicação da central"

  tags = { use_case = var.use_case }
}

# --------------------------------------------- AgentCore Observability ----
resource "aws_cloudwatch_log_group" "app" {
  name              = "/aws/vendedlogs/bedrock-agentcore/${var.name_prefix}/${var.use_case}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn

  tags = { use_case = var.use_case }
}

resource "aws_cloudwatch_log_delivery_source" "logs" {
  name         = "${var.name_prefix}-${var.use_case}-runtime-logs"
  log_type     = "APPLICATION_LOGS"
  resource_arn = aws_bedrockagentcore_agent_runtime.this.agent_runtime_arn
}

resource "aws_cloudwatch_log_delivery_source" "traces" {
  name         = "${var.name_prefix}-${var.use_case}-runtime-traces"
  log_type     = "TRACES"
  resource_arn = aws_bedrockagentcore_agent_runtime.this.agent_runtime_arn
}

resource "aws_cloudwatch_log_delivery_destination" "logs" {
  name = "${var.name_prefix}-${var.use_case}-runtime-cwl"

  delivery_destination_configuration {
    destination_resource_arn = aws_cloudwatch_log_group.app.arn
  }
}

resource "aws_cloudwatch_log_delivery_destination" "traces" {
  name                      = "${var.name_prefix}-${var.use_case}-runtime-xray"
  delivery_destination_type = "XRAY"
}

resource "aws_cloudwatch_log_delivery" "logs" {
  delivery_source_name     = aws_cloudwatch_log_delivery_source.logs.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.logs.arn
}

resource "aws_cloudwatch_log_delivery" "traces" {
  delivery_source_name     = aws_cloudwatch_log_delivery_source.traces.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.traces.arn

  depends_on = [aws_cloudwatch_log_delivery.logs]
}
