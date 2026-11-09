
# Project name
variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "digital-twin"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "Project name must contain only lowercase letters, numbers, and hyphens."
  }
}

# Deployment environment
variable "environment" {
  description = "Environment name (dev, test, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "Environment must be one of: dev, test, prod."
  }
}

# Amazon Bedrock model
variable "bedrock_model_id" {
  description = "Amazon Bedrock foundation model ID"
  type        = string
}

# Lambda configuration
variable "lambda_timeout" {
  description = "Lambda function timeout in seconds"
  type        = number
  default     = 60

  validation {
    condition     = var.lambda_timeout >= 1 && var.lambda_timeout <= 900
    error_message = "Lambda timeout must be between 1 and 900 seconds."
  }
}

# API Gateway throttling
variable "api_throttle_burst_limit" {
  description = "API Gateway throttle burst limit"
  type        = number
  default     = 10
}

variable "api_throttle_rate_limit" {
  description = "API Gateway throttle rate limit (requests per second)"
  type        = number
  default     = 5
}

# CloudFront custom domain
variable "use_custom_domain" {
  description = "Attach a custom domain to CloudFront"
  type        = bool
  default     = false
}

variable "root_domain" {
  description = "Apex domain name, e.g. mydomain.com"
  type        = string
  default     = ""

  validation {
    condition = !var.use_custom_domain || length(trimspace(var.root_domain)) > 0
    error_message = "Provide a root domain when use_custom_domain is true."
  }
}
