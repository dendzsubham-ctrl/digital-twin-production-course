
project_name             = "digital-twin"
environment              = "dev"

# Amazon Bedrock
bedrock_model_id         = "global.amazon.nova-2-lite-v1:0"

# AWS Lambda
lambda_timeout           = 60

# API Gateway throttling
api_throttle_burst_limit = 10
api_throttle_rate_limit  = 5

# CloudFront custom domain
use_custom_domain        = false
root_domain              = ""
