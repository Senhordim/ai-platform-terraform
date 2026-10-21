# Executado com uma role da conta de gerenciamento (OIDC no CI; SSO local).
provider "aws" {
  region = "sa-east-1"

  allowed_account_ids = [var.management_account_id]

  default_tags {
    tags = {
      project             = "ai-platform"
      environment         = "org"
      use_case            = "shared"
      owner               = var.owner
      cost_center         = var.cost_center
      data_classification = "interno"
    }
  }
}
