terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region = "ap-southeast-2"
  default_tags {
    tags = {
      Deployed_using = "Terraform"
      Stack          = "SeedBox"
    }
  }
}