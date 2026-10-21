# Backend S3 com criptografia (SSE-KMS) e lock nativo por arquivo
# (use_lockfile, sem DynamoDB). bucket e kms_key_id entram por
# -backend-config no pipeline; nenhuma credencial no código.
#
#   terraform init \
#     -backend-config="bucket=<bucket-de-state>" \
#     -backend-config="kms_key_id=<arn-da-cmk-do-state>"
terraform {
  backend "s3" {
    key          = "ai-platform/prd/terraform.tfstate"
    region       = "sa-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
