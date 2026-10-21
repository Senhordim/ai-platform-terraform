# Baseline de segurança da conta: AWS Config (recorder + regras básicas),
# GuardDuty e Macie (job de classificação no bucket de documentos).
# Se a organização já gerencia Config/GuardDuty/Macie por administrador
# delegado, desligue os toggles correspondentes para evitar conflito.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}

# ---------------------------------------------------------- AWS Config ----
module "config_bucket" {
  count  = var.enable_config ? 1 : 0
  source = "../s3-secure-bucket"

  name                   = "${var.bucket_prefix}-config"
  kms_key_arn            = var.logs_kms_key_arn
  access_log_bucket      = var.access_log_bucket
  force_destroy          = var.force_destroy
  additional_policy_json = data.aws_iam_policy_document.config_bucket.json
}

data "aws_iam_policy_document" "config_bucket" {
  statement {
    sid       = "AWSConfigBucketPermissionsCheck"
    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = ["arn:${local.partition}:s3:::${var.bucket_prefix}-config"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "AWSConfigBucketDelivery"
    actions   = ["s3:PutObject"]
    resources = ["arn:${local.partition}:s3:::${var.bucket_prefix}-config/AWSLogs/${local.account_id}/Config/*"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_service_linked_role" "config" {
  count            = var.enable_config && var.create_config_service_linked_role ? 1 : 0
  aws_service_name = "config.amazonaws.com"
}

resource "aws_config_configuration_recorder" "this" {
  count = var.enable_config ? 1 : 0

  name     = "${var.name_prefix}-recorder"
  role_arn = "arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig"

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }

  depends_on = [aws_iam_service_linked_role.config]
}

resource "aws_config_delivery_channel" "this" {
  count = var.enable_config ? 1 : 0

  name           = "${var.name_prefix}-delivery"
  s3_bucket_name = module.config_bucket[0].id
  s3_kms_key_arn = var.logs_kms_key_arn

  depends_on = [aws_config_configuration_recorder.this]
}

resource "aws_config_configuration_recorder_status" "this" {
  count = var.enable_config ? 1 : 0

  name       = aws_config_configuration_recorder.this[0].name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.this]
}

locals {
  config_rules = {
    cloudtrail-enabled                       = "CLOUD_TRAIL_ENABLED"
    cloudtrail-log-file-validation           = "CLOUD_TRAIL_LOG_FILE_VALIDATION_ENABLED"
    cloudwatch-log-group-encrypted           = "CLOUDWATCH_LOG_GROUP_ENCRYPTED"
    iam-root-access-key-check                = "IAM_ROOT_ACCESS_KEY_CHECK"
    iam-user-no-policies-check               = "IAM_USER_NO_POLICIES_CHECK"
    kms-cmk-not-scheduled-for-deletion       = "KMS_CMK_NOT_SCHEDULED_FOR_DELETION"
    s3-bucket-public-read-prohibited         = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
    s3-bucket-public-write-prohibited        = "S3_BUCKET_PUBLIC_WRITE_PROHIBITED"
    s3-bucket-ssl-requests-only              = "S3_BUCKET_SSL_REQUESTS_ONLY"
    s3-bucket-server-side-encryption-enabled = "S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED"
    vpc-default-security-group-closed        = "VPC_DEFAULT_SECURITY_GROUP_CLOSED"
    vpc-flow-logs-enabled                    = "VPC_FLOW_LOGS_ENABLED"
    guardduty-enabled-centralized            = "GUARDDUTY_ENABLED_CENTRALIZED"
  }
}

resource "aws_config_config_rule" "managed" {
  for_each = var.enable_config ? local.config_rules : {}

  name = "${var.name_prefix}-${each.key}"

  source {
    owner             = "AWS"
    source_identifier = each.value
  }

  depends_on = [aws_config_configuration_recorder_status.this]
}

# ------------------------------------------------------------ GuardDuty ----
resource "aws_guardduty_detector" "this" {
  #checkov:skip=CKV2_AWS_3:Detector da conta de workload; a centralização (administrador delegado) é feita no stack da organização.
  count = var.enable_guardduty ? 1 : 0

  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

resource "aws_guardduty_detector_feature" "this" {
  for_each = var.enable_guardduty ? toset(["S3_DATA_EVENTS", "RUNTIME_MONITORING"]) : toset([])

  detector_id = aws_guardduty_detector.this[0].id
  name        = each.value
  status      = "ENABLED"
}

# ---------------------------------------------------------------- Macie ----
resource "aws_macie2_account" "this" {
  count = var.enable_macie ? 1 : 0

  finding_publishing_frequency = "FIFTEEN_MINUTES"
  status                       = "ENABLED"
}

resource "aws_macie2_classification_job" "documents" {
  count = var.enable_macie && length(var.macie_bucket_names) > 0 ? 1 : 0

  name     = "${var.name_prefix}-documents"
  job_type = "SCHEDULED"

  schedule_frequency {
    daily_schedule = true
  }

  s3_job_definition {
    bucket_definitions {
      account_id = local.account_id
      buckets    = var.macie_bucket_names
    }
  }

  depends_on = [aws_macie2_account.this]
}
