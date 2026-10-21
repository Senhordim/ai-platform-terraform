terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 1.106"
    }
  }
}
