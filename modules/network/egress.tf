# Egress externo controlado — criado SOMENTE quando egress_allowed_domains
# não está vazia. Caminho: workload -> Network Firewall -> NAT -> IGW.
# O IGW fica associado apenas às subnets públicas (NAT); as subnets de
# workload nunca têm rota 0.0.0.0/0 para o IGW (a rota padrão aponta para o
# endpoint do firewall).

resource "aws_subnet" "firewall" {
  count = local.egress_enabled ? var.az_count : 0

  vpc_id               = aws_vpc.this.id
  cidr_block           = local.firewall_cidrs[count.index]
  availability_zone_id = local.azs[count.index]

  tags = { Name = "${var.name_prefix}-firewall-${local.azs[count.index]}", tier = "firewall" }
}

resource "aws_subnet" "public" {
  #checkov:skip=CKV_AWS_130:Subnet pública só hospeda o NAT Gateway; map_public_ip_on_launch=false.
  count = local.egress_enabled ? var.az_count : 0

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone_id    = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${var.name_prefix}-public-nat-${local.azs[count.index]}", tier = "public-nat" }
}

resource "aws_internet_gateway" "this" {
  count  = local.egress_enabled ? 1 : 0
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

resource "aws_eip" "nat" {
  count  = local.egress_enabled ? var.az_count : 0
  domain = "vpc"
  tags   = { Name = "${var.name_prefix}-nat-${local.azs[count.index]}" }
}

resource "aws_nat_gateway" "this" {
  count = local.egress_enabled ? var.az_count : 0

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = { Name = "${var.name_prefix}-nat-${local.azs[count.index]}" }

  depends_on = [aws_internet_gateway.this]
}

# Regras: allowlist de domínios (TLS SNI + HTTP Host). Tudo o mais é negado
# pela política (default action drop_established + alert).
resource "aws_networkfirewall_rule_group" "domain_allowlist" {
  count = local.egress_enabled ? 1 : 0

  name     = "${var.name_prefix}-egress-allowlist"
  type     = "STATEFUL"
  capacity = 100

  rule_group {
    rule_variables {
      ip_sets {
        key = "HOME_NET"
        ip_set {
          definition = [var.vpc_cidr]
        }
      }
    }

    rules_source {
      rules_source_list {
        generated_rules_type = "ALLOWLIST"
        target_types         = ["TLS_SNI", "HTTP_HOST"]
        targets              = var.egress_allowed_domains
      }
    }

    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }
  }

  encryption_configuration {
    type   = "CUSTOMER_KMS"
    key_id = var.data_kms_key_arn
  }
}

resource "aws_networkfirewall_firewall_policy" "this" {
  count = local.egress_enabled ? 1 : 0

  name = "${var.name_prefix}-egress"

  firewall_policy {
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]

    stateful_engine_options {
      rule_order = "STRICT_ORDER"
    }

    stateful_default_actions = ["aws:drop_established", "aws:alert_established"]

    stateful_rule_group_reference {
      priority     = 100
      resource_arn = aws_networkfirewall_rule_group.domain_allowlist[0].arn
    }
  }

  encryption_configuration {
    type   = "CUSTOMER_KMS"
    key_id = var.data_kms_key_arn
  }
}

resource "aws_networkfirewall_firewall" "this" {
  count = local.egress_enabled ? 1 : 0

  name                = "${var.name_prefix}-egress"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.this[0].arn
  vpc_id              = aws_vpc.this.id
  delete_protection   = var.deletion_protection

  dynamic "subnet_mapping" {
    for_each = aws_subnet.firewall[*].id
    content {
      subnet_id = subnet_mapping.value
    }
  }

  encryption_configuration {
    type   = "CUSTOMER_KMS"
    key_id = var.data_kms_key_arn
  }
}

resource "aws_cloudwatch_log_group" "firewall" {
  for_each = local.egress_enabled ? toset(["alert", "flow"]) : toset([])

  name              = "/aws/network-firewall/${var.name_prefix}/${each.key}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
}

resource "aws_networkfirewall_logging_configuration" "this" {
  count        = local.egress_enabled ? 1 : 0
  firewall_arn = aws_networkfirewall_firewall.this[0].arn

  logging_configuration {
    log_destination_config {
      log_destination_type = "CloudWatchLogs"
      log_type             = "ALERT"
      log_destination = {
        logGroup = aws_cloudwatch_log_group.firewall["alert"].name
      }
    }

    log_destination_config {
      log_destination_type = "CloudWatchLogs"
      log_type             = "FLOW"
      log_destination = {
        logGroup = aws_cloudwatch_log_group.firewall["flow"].name
      }
    }
  }
}

locals {
  # Endpoint do firewall por AZ (nome da AZ, como o firewall reporta).
  firewall_endpoints = local.egress_enabled ? {
    for s in aws_networkfirewall_firewall.this[0].firewall_status[0].sync_states :
    s.availability_zone => s.attachment[0].endpoint_id
  } : {}
}

# Rotas -------------------------------------------------------------------
resource "aws_route" "workload_default_to_firewall" {
  count = local.egress_enabled ? var.az_count : 0

  route_table_id         = aws_route_table.workload[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = local.firewall_endpoints[aws_subnet.workload[count.index].availability_zone]
}

resource "aws_route_table" "firewall" {
  count  = local.egress_enabled ? var.az_count : 0
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-firewall-${local.azs[count.index]}" }
}

resource "aws_route" "firewall_to_nat" {
  count = local.egress_enabled ? var.az_count : 0

  route_table_id         = aws_route_table.firewall[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[count.index].id
}

resource "aws_route_table_association" "firewall" {
  count          = local.egress_enabled ? var.az_count : 0
  subnet_id      = aws_subnet.firewall[count.index].id
  route_table_id = aws_route_table.firewall[count.index].id
}

resource "aws_route_table" "public" {
  count  = local.egress_enabled ? var.az_count : 0
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-public-nat-${local.azs[count.index]}" }
}

# Única rota 0.0.0.0/0 -> IGW da VPC, restrita às subnets do NAT.
resource "aws_route" "public_to_igw" {
  count = local.egress_enabled ? var.az_count : 0

  route_table_id         = aws_route_table.public[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

# Retorno simétrico: tráfego do NAT de volta para as subnets de workload
# passa novamente pelo firewall.
resource "aws_route" "public_return_via_firewall" {
  for_each = local.egress_enabled ? {
    for pair in setproduct(range(var.az_count), range(var.az_count)) : "${pair[0]}-${pair[1]}" => {
      rt_az  = pair[0]
      dst_az = pair[1]
    }
  } : {}

  route_table_id         = aws_route_table.public[each.value.rt_az].id
  destination_cidr_block = local.workload_cidrs[each.value.dst_az]
  vpc_endpoint_id        = local.firewall_endpoints[aws_subnet.public[each.value.rt_az].availability_zone]
}

resource "aws_route_table_association" "public" {
  count          = local.egress_enabled ? var.az_count : 0
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[count.index].id
}
