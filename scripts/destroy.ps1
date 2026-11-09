
param(
    [string]$ProjectName = "digital-twin"
)

$ErrorActionPreference = "Stop"

# Only the test environment can be destroyed
$Environment = "test"

Write-Host "`nPreparing to destroy $ProjectName-$Environment infrastructure..." -ForegroundColor Yellow

# Helper function: Execute external commands safely
function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $PreviousPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = "Continue"

        $Output = & $Command @Arguments 2>&1
        $ExitCode = $LASTEXITCODE

        return [PSCustomObject]@{
            ExitCode = $ExitCode
            Output   = ($Output | Out-String).Trim()
        }
    }
    catch {
        return [PSCustomObject]@{
            ExitCode = 1
            Output   = $_.Exception.Message
        }
    }
    finally {
        $ErrorActionPreference = $PreviousPreference
    }
}

# 1. Navigate to Terraform directory
$TerraformDir = Join-Path (Split-Path $PSScriptRoot -Parent) "terraform"

if (-not (Test-Path $TerraformDir)) {
    Write-Host "Error: Terraform directory not found." -ForegroundColor Red
    exit 1
}

Set-Location $TerraformDir

# 2. Check Terraform workspace
Write-Host "`nChecking Terraform workspaces..." -ForegroundColor Cyan

$WorkspaceResult = Invoke-ExternalCommand -Command "terraform" -Arguments @(
    "workspace", "list"
)

if ($WorkspaceResult.ExitCode -ne 0) {
    Write-Host $WorkspaceResult.Output -ForegroundColor Red
    exit 1
}

$workspaceNames = $WorkspaceResult.Output -split "`r?`n" | ForEach-Object {
    ($_ -replace '^\s*\*?\s*', '').Trim()
}

if ($workspaceNames -notcontains "test") {
    Write-Host "Error: Test workspace does not exist." -ForegroundColor Red
    exit 1
}

# 3. Select test workspace
$SelectResult = Invoke-ExternalCommand -Command "terraform" -Arguments @(
    "workspace", "select", "test"
)

if ($SelectResult.ExitCode -ne 0) {
    Write-Host $SelectResult.Output -ForegroundColor Red
    exit 1
}

Write-Host "Selected Terraform workspace: test" -ForegroundColor Green

# 4. Verify AWS identity
Write-Host "`nChecking AWS account..." -ForegroundColor Cyan

$IdentityResult = Invoke-ExternalCommand -Command "aws" -Arguments @(
    "sts",
    "get-caller-identity",
    "--query",
    "Account",
    "--output",
    "text"
)

if ($IdentityResult.ExitCode -ne 0 -or
    [string]::IsNullOrWhiteSpace($IdentityResult.Output)) {

    Write-Host "Error: AWS identity verification failed." -ForegroundColor Red
    Write-Host $IdentityResult.Output
    exit 1
}

$awsAccountId = $IdentityResult.Output.Trim()

Write-Host "AWS Account: $awsAccountId" -ForegroundColor Green

# 5. Define test S3 buckets using correct naming convention
$FrontendBucket = "$ProjectName-test-frontend-$awsAccountId"
$MemoryBucket = "$ProjectName-test-memory-$awsAccountId"

Write-Host "`nFrontend Bucket: $FrontendBucket"
Write-Host "Memory Bucket: $MemoryBucket"

# 6. Confirm destruction
Write-Host "`nWARNING: This will permanently destroy TEST infrastructure and data!" -ForegroundColor Red
Write-Host "Development and production environments will not be intentionally targeted." -ForegroundColor Yellow

$confirmation = Read-Host "Type DESTROY TEST to continue"

if ($confirmation -cne "DESTROY TEST") {
    Write-Host "Destruction cancelled." -ForegroundColor Yellow
    exit 0
}

# 7. Empty test S3 buckets
foreach ($Bucket in @($FrontendBucket, $MemoryBucket)) {

    Write-Host "`nChecking bucket: $Bucket" -ForegroundColor Cyan

    $BucketResult = Invoke-ExternalCommand -Command "aws" -Arguments @(
        "s3api",
        "head-bucket",
        "--bucket",
        $Bucket
    )

    if ($BucketResult.ExitCode -ne 0) {
        Write-Host "Error: Could not verify bucket $Bucket." -ForegroundColor Red
        Write-Host "AWS response: $($BucketResult.Output)" -ForegroundColor Yellow
        Write-Host "Terraform destroy has NOT been started." -ForegroundColor Yellow
        exit 1
    }

    Write-Host "Emptying bucket: $Bucket" -ForegroundColor Yellow

    $DeleteResult = Invoke-ExternalCommand -Command "aws" -Arguments @(
        "s3",
        "rm",
        "s3://$Bucket",
        "--recursive"
    )

    if ($DeleteResult.ExitCode -ne 0) {
        Write-Host "Error: Failed to empty bucket $Bucket." -ForegroundColor Red
        Write-Host $DeleteResult.Output
        Write-Host "Terraform destroy has NOT been started." -ForegroundColor Yellow
        exit 1
    }

    Write-Host "Bucket emptied successfully: $Bucket" -ForegroundColor Green
}

# 8. Run Terraform destroy for test only
Write-Host "`nRunning Terraform destroy for TEST..." -ForegroundColor Yellow

$DestroyArguments = @(
    "destroy",
    "-var=project_name=$ProjectName",
    "-var=environment=test",
    "-auto-approve"
)

$DestroyResult = Invoke-ExternalCommand -Command "terraform" -Arguments $DestroyArguments

if ($DestroyResult.Output) {
    Write-Host $DestroyResult.Output
}

# 9. Verify Terraform destruction
if ($DestroyResult.ExitCode -ne 0) {
    Write-Host "`nERROR: Terraform destroy failed!" -ForegroundColor Red
    Write-Host "Check Terraform state and AWS resources." -ForegroundColor Yellow
    exit 1
}

# 10. Success message
Write-Host "`nTEST infrastructure destroyed successfully!" -ForegroundColor Green

# 11. Workspace cleanup instructions
Write-Host "`nThe test Terraform workspace has NOT been deleted." -ForegroundColor Cyan
Write-Host "To remove it manually, run:" -ForegroundColor Cyan
Write-Host "terraform workspace select default" -ForegroundColor White
Write-Host "terraform workspace delete test" -ForegroundColor White
