# Bucket S3 "seguro por padrão": KMS (CMK), versionamento, bloqueio de acesso
# público, BucketOwnerEnforced, TLS obrigatório e (opcional) Object Lock e
# access logging. Usado por todos os outros módulos.

resource "aws_s3_bucket" "this" {
  #checkov:skip=CKV_AWS_144:Replicação cross-region contraria a residência de dados (só sa-east-1).
  #checkov:skip=CKV2_AWS_62:Notificações de evento não são necessárias para este bucket.
  #checkov:skip=CKV_AWS_18:Access logging é configurado abaixo quando access_log_bucket é informado; o próprio bucket de access logs não loga em si mesmo.
  bucket              = var.name
  force_destroy       = var.force_destroy
  object_lock_enabled = var.object_lock != null

  tags = var.tags
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      # ALB access logs só aceitam SSE-S3; nos demais casos usamos a CMK do domínio.
      sse_algorithm     = var.kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = var.kms_key_arn != null
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "base"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    dynamic "noncurrent_version_expiration" {
      for_each = var.noncurrent_version_expiration_days == null ? [] : [1]
      content {
        noncurrent_days = var.noncurrent_version_expiration_days
      }
    }

    dynamic "expiration" {
      for_each = var.expiration_days == null ? [] : [1]
      content {
        days = var.expiration_days
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

resource "aws_s3_bucket_object_lock_configuration" "this" {
  count  = var.object_lock == null ? 0 : 1
  bucket = aws_s3_bucket.this.id

  rule {
    default_retention {
      mode = var.object_lock.mode
      days = var.object_lock.retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

resource "aws_s3_bucket_logging" "this" {
  count  = var.access_log_bucket == null ? 0 : 1
  bucket = aws_s3_bucket.this.id

  target_bucket = var.access_log_bucket
  target_prefix = "${var.name}/"
}

data "aws_iam_policy_document" "this" {
  source_policy_documents = var.additional_policy_json == null ? [] : [var.additional_policy_json]

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"] # Deny amplo é o padrão recomendado pela AWS para TLS obrigatório.
    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  dynamic "statement" {
    for_each = var.kms_key_arn == null || !var.deny_unencrypted_uploads ? [] : [1]
    content {
      sid       = "DenyWrongKmsKey"
      effect    = "Deny"
      actions   = ["s3:PutObject"]
      resources = ["${aws_s3_bucket.this.arn}/*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "StringNotEqualsIfExists"
        variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
        values   = [var.kms_key_arn]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.this.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}
