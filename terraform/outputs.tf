
# API Gateway endpoint
output "api_gateway_url" {
  description = "Base URL of the API Gateway"
  value       = aws_apigatewayv2_api.main.api_endpoint
}

# CloudFront frontend URL
output "cloudfront_url" {
  description = "URL of the CloudFront distribution"
  value       = "https://${aws_cloudfront_distribution.main.domain_name}"
}

# Frontend S3 bucket
output "s3_frontend_bucket" {
  description = "Name of the S3 bucket hosting frontend files"
  value       = aws_s3_bucket.frontend.id
}

# Conversation memory S3 bucket
output "s3_memory_bucket" {
  description = "Name of the S3 bucket storing conversation memory"
  value       = aws_s3_bucket.memory.id
}

# Lambda function
output "lambda_function_name" {
  description = "Name of the Digital Twin Lambda function"
  value       = aws_lambda_function.api.function_name
}

# Custom domain
output "custom_domain_url" {
  description = "Root URL of the custom domain"
  value       = var.use_custom_domain ? "https://${var.root_domain}" : null
}

# AWS region
output "aws_region" {
  description = "AWS region where the primary infrastructure is deployed"
  value       = "ap-southeast-2"
}
