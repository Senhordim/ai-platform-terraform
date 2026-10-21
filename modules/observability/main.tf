# ⑤ Observabilidade (parte "de conta"):
# - bucket central de S3 access logs;
# - CloudTrail entregando em bucket com S3 Object Lock (WORM) + CloudWatch Logs;
# - X-Ray Transaction Search (spans em CloudWatch Logs) — pré-requisito do
#   AgentCore Observability; a entrega de logs/traces de cada Runtime e do
#   Gateway é ligada nos módulos agent-runtime e tool-gateway;
# - saída para o SIEM via subscription filters para um CloudWatch Logs
#   destination (cross-account) — sem chaves estáticas.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  trail_name = "${var.name_prefix}-trail"
  trail_arn  = "arn:${local.partition}:cloudtrail:${local.region}:${local.account_id}:trail/${local.trail_name}"
}

# --------------------------------------------------- access log bucket ----
module "access_logs_bucket" {
  source = "../s3-secure-bucket"

  name                               = "${var.bucket_prefix}-s3-access-logs"
  kms_key_arn                        = null # Server access logging não suporta SSE-KMS no bucket de destino.
  expiration_days                    = var.access_logs_expiration_days
  noncurrent_version_expiration_days = 30
  force_destroy                      = var.force_destroy
  additional_policy_json             = data.aws_iam_policy_document.access_logs.json
}

data "aws_iam_policy_document" "access_logs" {
  statement {
    sid       = "S3ServerAccessLogs"
    actions   = ["s3:PutObject"]
    resources = ["arn:${local.partition}:s3:::${var.bucket_prefix}-s3-access-logs/*"]
    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

# ---------------------------------------------------------- CloudTrail ----
module "cloudtrail_bucket" {
  source = "../s3-secure-bucket"

  name        = "${var.bucket_prefix}-cloudtrail"
  kms_key_arn = var.logs_kms_key_arn
  object_lock = {
    mode           = var.cloudtrail_object_lock_mode
    retention_days = var.cloudtrail_object_lock_days
  }
  noncurrent_version_expiration_days = null
  access_log_bucket                  = module.access_logs_bucket.id
  force_destroy                      = false
  additional_policy_json             = data.aws_iam_policy_document.cloudtrail_bucket.json
}

data "aws_iam_policy_document" "cloudtrail_bucket" {
  statement {
    sid       = "CloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = ["arn:${local.partition}:s3:::${var.bucket_prefix}-cloudtrail"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "CloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["arn:${local.partition}:s3:::${var.bucket_prefix}-cloudtrail/AWSLogs/${local.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
}

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/${local.trail_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
}

data "aws_iam_policy_document" "cloudtrail_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
}

resource "aws_iam_role" "cloudtrail" {
  name               = "${var.name_prefix}-cloudtrail-to-cwl"
  assume_role_policy = data.aws_iam_policy_document.cloudtrail_assume.json
}

data "aws_iam_policy_document" "cloudtrail_cwl" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.cloudtrail.arn}:log-stream:*"]
  }
}

resource "aws_iam_role_policy" "cloudtrail" {
  name   = "write-cloudwatch-logs"
  role   = aws_iam_role.cloudtrail.id
  policy = data.aws_iam_policy_document.cloudtrail_cwl.json
}

resource "aws_cloudtrail" "this" {
  #checkov:skip=CKV_AWS_252:Alertas saem do CloudWatch Logs/SIEM (subscription filter), não de SNS por arquivo entregue.
  name                          = local.trail_name
  s3_bucket_name                = module.cloudtrail_bucket.id
  kms_key_id                    = var.logs_kms_key_arn
  enable_log_file_validation    = true
  include_global_service_events = true
  # Trail multi-região: registra (e evidencia) qualquer tentativa de uso fora
  # de sa-east-1, que as SCPs já negam. O trail em si vive em sa-east-1.
  is_multi_region_trail      = true
  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail.arn

  advanced_event_selector {
    name = "Management events"
    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  dynamic "advanced_event_selector" {
    for_each = length(var.cloudtrail_data_event_bucket_arns) > 0 ? [1] : []
    content {
      name = "S3 data events — buckets sensíveis"
      field_selector {
        field  = "eventCategory"
        equals = ["Data"]
      }
      field_selector {
        field  = "resources.type"
        equals = ["AWS::S3::Object"]
      }
      field_selector {
        field       = "resources.ARN"
        starts_with = [for b in var.cloudtrail_data_event_bucket_arns : "${b}/"]
      }
    }
  }

  depends_on = [module.cloudtrail_bucket]
}

# ------------------------------------------------ X-Ray Transaction Search ----
data "aws_iam_policy_document" "xray_to_cwl" {
  statement {
    sid     = "TransactionSearchXRayAccess"
    actions = ["logs:PutLogEvents"]
    resources = [
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:aws/spans:*",
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/application-signals/data:*",
    ]
    principals {
      type        = "Service"
      identifiers = ["xray.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:xray:${local.region}:${local.account_id}:*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "xray" {
  policy_name     = "${var.name_prefix}-xray-transaction-search"
  policy_document = data.aws_iam_policy_document.xray_to_cwl.json
}

resource "aws_xray_trace_segment_destination" "this" {
  destination = "CloudWatchLogs"

  depends_on = [aws_cloudwatch_log_resource_policy.xray]
}

resource "aws_xray_indexing_rule" "default" {
  name = "Default"

  rule {
    probabilistic {
      desired_sampling_percentage = var.xray_indexing_percentage
    }
  }

  depends_on = [aws_xray_trace_segment_destination.this]
}

# ---------------------------------------------------------------- SIEM ----
# Envia os log groups listados para um CloudWatch Logs destination na conta
# do SIEM (que, por sua vez, entrega em Kinesis/Firehose do lado do SIEM).
# A policy do destination precisa autorizar esta conta (feito no lado SIEM).
resource "aws_cloudwatch_log_subscription_filter" "siem" {
  for_each = var.siem_destination_arn == null ? {} : var.siem_log_group_names

  name            = "${var.name_prefix}-siem-${each.key}"
  log_group_name  = each.value
  filter_pattern  = ""
  destination_arn = var.siem_destination_arn
  distribution    = "ByLogStream"
}
