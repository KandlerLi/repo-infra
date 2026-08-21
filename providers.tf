terraform {
  required_version = ">= 1.10.0"

  required_providers {
    github = {
      source = "hashicorp/github"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "jkandler-terraform-state"
    key          = "repo-infra/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "eu-central-1"
}
