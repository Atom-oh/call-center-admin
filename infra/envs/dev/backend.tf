terraform {
  required_version = ">= 1.6"
  backend "s3" {
    bucket         = "kakaopay-callcenter-tfstate"
    key            = "envs/dev/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "kakaopay-callcenter-tflock"
    encrypt        = true
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}
