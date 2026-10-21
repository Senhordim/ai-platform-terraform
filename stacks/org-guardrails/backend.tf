# Estado na conta de gerenciamento (ou de "deployments"). Valores por
# -backend-config no pipeline; nada de credenciais aqui.
terraform {
  backend "s3" {
    key          = "org-guardrails/ai-platform-scps.tfstate"
    region       = "sa-east-1"
    encrypt      = true
    use_lockfile = true
    # bucket     = "<bucket-de-state>"        -> -backend-config
    # kms_key_id = "<arn-da-cmk-do-state>"    -> -backend-config
  }
}
