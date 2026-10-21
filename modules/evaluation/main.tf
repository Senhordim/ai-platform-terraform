# ⑥ Avaliação — apenas recursos de suporte. O pipeline de CI/CD fica fora do
# escopo; ele se conecta assim:
#   1. o job do CI assume `pipeline_role` via OIDC (sem access keys);
#   2. lê o golden set em s3://<bucket>/golden-sets/<use_case>/;
#   3. invoca o endpoint do AgentCore Runtime do caso (InvokeAgentRuntime)
#      com tokens de teste do IdP;
#   4. grava resultados em s3://<bucket>/results/<use_case>/<run_id>/ e
#      bloqueia a promoção dev -> prd se as métricas caírem abaixo do limiar.

module "golden_sets_bucket" {
  source = "../s3-secure-bucket"

  name                     = "${var.bucket_prefix}-evaluation"
  kms_key_arn              = var.data_kms_key_arn
  deny_unencrypted_uploads = true
  access_log_bucket        = var.access_log_bucket
  force_destroy            = var.force_destroy
}

data "aws_iam_policy_document" "pipeline_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.ci_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.ci_oidc_provider_host}:aud"
      values   = [var.ci_oidc_audience]
    }
    condition {
      test     = "StringLike"
      variable = "${var.ci_oidc_provider_host}:sub"
      values   = var.ci_oidc_subjects
    }
  }
}

resource "aws_iam_role" "pipeline" {
  name                 = "${var.name_prefix}-evaluation-pipeline"
  description          = "Assumida pelo pipeline de avaliação via OIDC"
  assume_role_policy   = data.aws_iam_policy_document.pipeline_assume.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "pipeline" {
  statement {
    sid       = "ListGoldenSets"
    actions   = ["s3:ListBucket"]
    resources = [module.golden_sets_bucket.arn]
  }

  statement {
    sid       = "ReadGoldenSets"
    actions   = ["s3:GetObject"]
    resources = [for uc in var.use_case_names : "${module.golden_sets_bucket.arn}/golden-sets/${uc}/*"]
  }

  statement {
    sid       = "WriteResults"
    actions   = ["s3:PutObject"]
    resources = [for uc in var.use_case_names : "${module.golden_sets_bucket.arn}/results/${uc}/*"]
  }

  statement {
    sid       = "UseDataKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.data_kms_key_arn]
  }

  dynamic "statement" {
    for_each = length(var.agent_runtime_arns) > 0 ? [1] : []
    content {
      sid       = "InvokeAgentsUnderTest"
      actions   = ["bedrock-agentcore:InvokeAgentRuntime"]
      resources = concat(var.agent_runtime_arns, [for a in var.agent_runtime_arns : "${a}/*"])
    }
  }
}

resource "aws_iam_role_policy" "pipeline" {
  name   = "evaluation"
  role   = aws_iam_role.pipeline.id
  policy = data.aws_iam_policy_document.pipeline.json
}
