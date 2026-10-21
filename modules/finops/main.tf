# FinOps
# - AWS Budgets por caso de uso (filtro pela tag de alocação use_case), alerta
#   em 80% e budget action em 100% que anexa uma policy de bloqueio de
#   invocação à role do caso (aprovação automática).
# - Exportação CUR 2.0 (BCM Data Exports) para S3 em sa-east-1.
# Pré-requisito: ativar a tag `use_case` como cost allocation tag (Billing,
# na conta de gerenciamento) — ver README.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
}

# ---------------------------------------------------- Budgets por caso ----
resource "aws_budgets_budget" "use_case" {
  for_each = var.use_cases

  name         = "${var.name_prefix}-uc-${each.key}"
  budget_type  = "COST"
  limit_amount = format("%.2f", each.value.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:use_case$%s", each.key)]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
    subscriber_sns_topic_arns  = var.budget_alert_sns_topic_arns
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.budget_alert_emails
    subscriber_sns_topic_arns  = var.budget_alert_sns_topic_arns
  }

  tags = { use_case = each.key }
}

data "aws_iam_policy_document" "budgets_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "budget_action" {
  name               = "${var.name_prefix}-budget-actions"
  assume_role_policy = data.aws_iam_policy_document.budgets_assume.json
}

data "aws_iam_policy_document" "budget_action" {
  statement {
    sid       = "AttachOnlyBlockPolicyToUseCaseRoles"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = [for uc in var.use_cases : uc.role_arn]
    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = [for uc in var.use_cases : uc.block_policy_arn]
    }
  }
}

resource "aws_iam_role_policy" "budget_action" {
  name   = "attach-budget-block"
  role   = aws_iam_role.budget_action.id
  policy = data.aws_iam_policy_document.budget_action.json
}

resource "aws_budgets_budget_action" "block_at_100" {
  for_each = var.use_cases

  budget_name        = aws_budgets_budget.use_case[each.key].name
  action_type        = "APPLY_IAM_POLICY"
  approval_model     = "AUTOMATIC"
  notification_type  = "ACTUAL"
  execution_role_arn = aws_iam_role.budget_action.arn

  action_threshold {
    action_threshold_type  = "PERCENTAGE"
    action_threshold_value = 100
  }

  definition {
    iam_action_definition {
      policy_arn = each.value.block_policy_arn
      roles      = [each.value.role_name]
    }
  }

  dynamic "subscriber" {
    for_each = var.budget_alert_emails
    content {
      address           = subscriber.value
      subscription_type = "EMAIL"
    }
  }

  dynamic "subscriber" {
    for_each = var.budget_alert_sns_topic_arns
    content {
      address           = subscriber.value
      subscription_type = "SNS"
    }
  }

  lifecycle {
    precondition {
      condition     = length(var.budget_alert_emails) + length(var.budget_alert_sns_topic_arns) > 0
      error_message = "Informe ao menos um e-mail ou tópico SNS para as budget actions."
    }
  }

  depends_on = [aws_iam_role_policy.budget_action]
}

# ---------------------------------------------------- CUR 2.0 export ----
module "cur_bucket" {
  source = "../s3-secure-bucket"

  name                   = "${var.bucket_prefix}-cur"
  kms_key_arn            = var.data_kms_key_arn
  access_log_bucket      = var.access_log_bucket
  force_destroy          = var.force_destroy
  additional_policy_json = data.aws_iam_policy_document.cur_bucket.json
}

data "aws_iam_policy_document" "cur_bucket" {
  statement {
    sid       = "EnableAWSDataExportsToWriteToS3AndCheckPolicy"
    actions   = ["s3:PutObject", "s3:GetBucketPolicy"]
    resources = ["arn:${local.partition}:s3:::${var.bucket_prefix}-cur", "arn:${local.partition}:s3:::${var.bucket_prefix}-cur/*"]
    principals {
      type        = "Service"
      identifiers = ["billingreports.amazonaws.com", "bcm-data-exports.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:SourceArn"
      values = [
        "arn:${local.partition}:cur:us-east-1:${local.account_id}:definition/*",
        "arn:${local.partition}:bcm-data-exports:us-east-1:${local.account_id}:export/*",
      ]
    }
    condition {
      test     = "StringLike"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

# BCM Data Exports é um serviço global (plano de controle em us-east-1); o
# dado é entregue no bucket em sa-east-1 (s3_region).
resource "aws_bcmdataexports_export" "cur2" {
  count = var.enable_cur_export ? 1 : 0

  export {
    name        = "${var.name_prefix}-cur2"
    description = "CUR 2.0 da conta AI Platform (com tags de alocação)"

    data_query {
      query_statement = "SELECT bill_billing_period_start_date, line_item_usage_start_date, line_item_usage_account_id, line_item_product_code, line_item_usage_type, line_item_operation, line_item_resource_id, line_item_usage_amount, line_item_unblended_cost, line_item_net_unblended_cost, product_region_code, resource_tags FROM COST_AND_USAGE_REPORT"
      table_configurations = {
        COST_AND_USAGE_REPORT = {
          BILLING_VIEW_ARN                      = "arn:${local.partition}:billing::${local.account_id}:billingview/primary"
          TIME_GRANULARITY                      = "HOURLY"
          INCLUDE_RESOURCES                     = "TRUE"
          INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY = "FALSE"
          INCLUDE_SPLIT_COST_ALLOCATION_DATA    = "FALSE"
        }
      }
    }

    destination_configurations {
      s3_destination {
        s3_bucket = module.cur_bucket.id
        s3_prefix = "cur2"
        s3_region = local.region

        s3_output_configurations {
          overwrite   = "OVERWRITE_REPORT"
          format      = "PARQUET"
          compression = "PARQUET"
          output_type = "CUSTOM"
        }
      }
    }

    refresh_cadence {
      frequency = "SYNCHRONOUS"
    }
  }

  depends_on = [module.cur_bucket]
}
