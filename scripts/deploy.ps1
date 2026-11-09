
param(
    [ValidateSet('dev', 'test', 'prod')]
    [string]$Environment = 'dev',
    [string]$ProjectName = 'digital-twin'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Invoke-Checked {
    param(
        [string]$Label,
        [scriptblock]$Command
    )

    Write-Host "`n$Label" -ForegroundColor Yellow
    & $Command

    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed (exit code $LASTEXITCODE)."
    }
}

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BackendDir = Join-Path $ProjectRoot 'backend'
$TerraformDir = Join-Path $ProjectRoot 'terraform'
$FrontendDir = Join-Path $ProjectRoot 'frontend'

foreach ($dir in @($BackendDir, $TerraformDir, $FrontendDir)) {
    if (-not (Test-Path -Path $dir -PathType Container)) {
        throw "Missing directory: $dir"
    }
}

foreach ($command in @('uv', 'terraform', 'npm', 'aws')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' was not found in PATH."
    }
}

Write-Host "Deploying $ProjectName to $Environment" -ForegroundColor Green

try {
    # 1. Build Lambda deployment package
    Set-Location $BackendDir

    if (-not (Test-Path './deploy.py')) {
        throw 'Missing backend/deploy.py'
    }

    Invoke-Checked 'Building Lambda package' {
        uv run deploy.py
    }

    if (-not (Test-Path './lambda-deployment.zip')) {
        throw 'Expected backend/lambda-deployment.zip was not created.'
    }

    # 2. Initialize Terraform
    Set-Location $TerraformDir

    Invoke-Checked 'Initializing Terraform' {
        terraform init -input=false
    }

    # 3. Select or create workspace
    $workspaceNames = @(
        terraform workspace list -no-color |
        ForEach-Object {
            ($_ -replace '^\s*\*?\s*', '').Trim()
        } |
        Where-Object { $_ }
    )

    if ($LASTEXITCODE -ne 0) {
        throw 'Could not list Terraform workspaces.'
    }

    if ($workspaceNames -contains $Environment) {
        Invoke-Checked "Selecting workspace $Environment" {
            terraform workspace select $Environment
        }
    } else {
        Invoke-Checked "Creating workspace $Environment" {
            terraform workspace new $Environment
        }
    }

    # 4. Set Terraform variables
    $tfArgs = @(
        '-var', "project_name=$ProjectName",
        '-var', "environment=$Environment"
    )

    if ($Environment -eq 'prod') {
        if (-not (Test-Path './prod.tfvars')) {
            throw 'Production requires terraform/prod.tfvars.'
        }

        $tfArgs += '-var-file=prod.tfvars'
    }

    # 5. Validate and plan
    Invoke-Checked 'Validating Terraform' {
        terraform validate
    }

    Invoke-Checked 'Planning infrastructure changes' {
        terraform plan @tfArgs -out=tfplan
    }

    Write-Host 'Review the plan before approving.' -ForegroundColor Cyan

    # 6. Apply reviewed plan
    Invoke-Checked 'Applying reviewed Terraform plan' {
        terraform apply tfplan
    }

    # 7. Retrieve Terraform outputs
    $ApiUrl = (terraform output -raw api_gateway_url).Trim()

    if ($LASTEXITCODE -ne 0 -or -not $ApiUrl) {
        throw 'Could not read API Gateway URL.'
    }

    $FrontendBucket = (
        terraform output -raw s3_frontend_bucket
    ).Trim()

    if ($LASTEXITCODE -ne 0 -or -not $FrontendBucket) {
        throw 'Could not read frontend S3 bucket.'
    }

    $CfUrl = (
        terraform output -raw cloudfront_url
    ).Trim()

    if ($LASTEXITCODE -ne 0 -or -not $CfUrl) {
        throw 'Could not read CloudFront URL.'
    }

    # 8. Build frontend
    Set-Location $FrontendDir

    "NEXT_PUBLIC_API_URL=$ApiUrl" |
        Set-Content -Path '.env.production' -Encoding utf8

    Invoke-Checked 'Installing frontend dependencies' {
        npm ci
    }

    Invoke-Checked 'Building static frontend' {
        npm run build
    }

    if (-not (Test-Path './out' -PathType Container)) {
        throw 'Frontend build did not create frontend/out.'
    }

    # 9. Upload frontend to S3
    Invoke-Checked 'Uploading frontend to S3' {
        aws s3 sync './out' "s3://$FrontendBucket/" --delete
    }

    # 10. Deployment summary
    Write-Host "`nDeployment complete!" -ForegroundColor Green
    Write-Host "CloudFront URL : $CfUrl" -ForegroundColor Cyan
    Write-Host "API Gateway    : $ApiUrl" -ForegroundColor Cyan
    Write-Host "Frontend bucket: $FrontendBucket" -ForegroundColor Cyan
}
finally {
    Set-Location $ProjectRoot
}
