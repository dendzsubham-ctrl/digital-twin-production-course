
terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Primary AWS provider
provider "aws" {
  region = "ap-southeast-2"
}

# Secondary AWS provider
# Required for resources such as CloudFront ACM certificates
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
