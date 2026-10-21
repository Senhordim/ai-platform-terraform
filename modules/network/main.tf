# VPC da conta "AI Platform".
# - Subnets privadas de workload em 2 AZs, SEM rota para Internet Gateway.
# - VPC endpoints de interface (PrivateLink) para todos os serviços usados e
#   gateway endpoint para S3: tráfego de modelo nunca sai para a internet.
# - Egress externo opcional, só via AWS Network Firewall com allowlist de
#   domínios (lista vazia = nenhum caminho de saída é criado).
# - Conectividade com o data center (Direct Connect) via Transit Gateway
#   existente, opcional.

data "aws_region" "current" {}

locals {
  region = data.aws_region.current.region
  # AZ IDs fixos (iguais em todas as contas, ao contrário dos nomes).
  azs = slice(var.availability_zone_ids, 0, var.az_count)

  egress_enabled = length(var.egress_allowed_domains) > 0
  tgw_enabled    = var.transit_gateway_id != null

  # /16 -> workload /20 (0,1), endpoints /24, firewall /28 e public /28.
  workload_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  endpoint_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, 32 + i)]
  firewall_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 12, 1024 + i)]
  public_cidrs   = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 12, 1040 + i)]
  tgw_cidrs      = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 12, 1056 + i)]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name_prefix}-vpc" }
}

# Fecha o default security group (CIS 5.4).
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-default-closed" }
}

# ------------------------------------------------------------ subnets ----
resource "aws_subnet" "workload" {
  count = var.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.workload_cidrs[count.index]
  availability_zone_id    = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${var.name_prefix}-workload-${local.azs[count.index]}", tier = "workload" }
}

resource "aws_subnet" "endpoints" {
  count = var.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.endpoint_cidrs[count.index]
  availability_zone_id    = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${var.name_prefix}-endpoints-${local.azs[count.index]}", tier = "endpoints" }
}

resource "aws_subnet" "tgw" {
  count = local.tgw_enabled ? var.az_count : 0

  vpc_id               = aws_vpc.this.id
  cidr_block           = local.tgw_cidrs[count.index]
  availability_zone_id = local.azs[count.index]

  tags = { Name = "${var.name_prefix}-tgw-${local.azs[count.index]}", tier = "tgw" }
}

resource "aws_route_table" "workload" {
  count  = var.az_count
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-workload-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "workload" {
  count          = var.az_count
  subnet_id      = aws_subnet.workload[count.index].id
  route_table_id = aws_route_table.workload[count.index].id
}

resource "aws_route_table" "endpoints" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-endpoints" }
}

resource "aws_route_table_association" "endpoints" {
  count          = var.az_count
  subnet_id      = aws_subnet.endpoints[count.index].id
  route_table_id = aws_route_table.endpoints.id
}

# ------------------------------------------------- Direct Connect (TGW) ----
resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  count = local.tgw_enabled ? 1 : 0

  transit_gateway_id = var.transit_gateway_id
  vpc_id             = aws_vpc.this.id
  subnet_ids         = aws_subnet.tgw[*].id
  dns_support        = "enable"

  tags = { Name = "${var.name_prefix}-tgw-attachment" }
}

resource "aws_route" "workload_to_onprem" {
  for_each = local.tgw_enabled ? {
    for pair in setproduct(range(var.az_count), var.onprem_cidrs) : "${pair[0]}-${pair[1]}" => {
      az   = pair[0]
      cidr = pair[1]
    }
  } : {}

  route_table_id         = aws_route_table.workload[each.value.az].id
  destination_cidr_block = each.value.cidr
  transit_gateway_id     = var.transit_gateway_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

# ----------------------------------------------------- VPC Flow Logs ----
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/${var.name_prefix}/flow-logs"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [aws_vpc.this.owner_id]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${var.name_prefix}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs.json
}

resource "aws_flow_log" "this" {
  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn         = aws_iam_role.flow_logs.arn
}

# ---------------------------------------------------- VPC endpoints ----
resource "aws_security_group" "endpoints" {
  name        = "${var.name_prefix}-vpce"
  description = "Interface VPC endpoints: HTTPS apenas a partir da VPC"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-vpce" }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.endpoints.id
  description       = "HTTPS a partir da VPC"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = aws_vpc.this.cidr_block
}

resource "aws_vpc_security_group_egress_rule" "endpoints_vpc" {
  security_group_id = aws_security_group.endpoints.id
  description       = "Respostas restritas à VPC"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = aws_vpc.this.cidr_block
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(concat(var.interface_endpoint_services, var.additional_interface_endpoint_services))

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${local.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.endpoints[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.name_prefix}-${each.value}" }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(aws_route_table.workload[*].id, [aws_route_table.endpoints.id])

  tags = { Name = "${var.name_prefix}-s3" }
}

# Security group padrão para workloads (AgentCore Runtime, Lattice ENIs do
# Gateway, NLB/ALB): saída apenas para a VPC, para o on-prem e para a lista de
# prefixos do S3 (gateway endpoint).
resource "aws_security_group" "workload" {
  #checkov:skip=CKV2_AWS_5:Anexado em outros módulos (AgentCore Runtime, ENIs do Gateway, VPCE do AOSS) — o checkov não segue referências entre módulos.
  name        = "${var.name_prefix}-workload"
  description = "Workloads da plataforma de agentes"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-workload" }
}

resource "aws_vpc_security_group_egress_rule" "workload_vpc" {
  security_group_id = aws_security_group.workload.id
  description       = "HTTPS para endpoints e serviços dentro da VPC"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = aws_vpc.this.cidr_block
}

resource "aws_vpc_security_group_egress_rule" "workload_s3" {
  security_group_id = aws_security_group.workload.id
  description       = "HTTPS para S3 via gateway endpoint"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = aws_vpc_endpoint.s3.prefix_list_id
}

resource "aws_vpc_security_group_egress_rule" "workload_onprem" {
  for_each = toset(var.onprem_cidrs)

  security_group_id = aws_security_group.workload.id
  description       = "HTTPS para APIs do core via Direct Connect"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "workload_self" {
  security_group_id            = aws_security_group.workload.id
  description                  = "HTTPS entre workloads"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.workload.id
}
