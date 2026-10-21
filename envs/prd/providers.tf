# Credenciais: role assumida via OIDC no CI ou IAM Identity Center (SSO)
# localmente. Nenhuma chave estática.
provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      project             = var.project
      environment         = var.environment
      use_case            = "shared" # sobrescrita nos recursos de cada caso de uso
      owner               = var.owner
      cost_center         = var.cost_center
      data_classification = var.data_classification
    }
  }
}

provider "awscc" {
  region = var.region
}
