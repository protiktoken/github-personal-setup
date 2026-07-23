$ErrorActionPreference = 'Stop'
$SetupArguments = @($args)

function Stop-WithError {
    param([string]$Message)

    [Console]::Error.WriteLine("Error: $Message")
    exit 1
}

$SourceRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$CleanupToken = $env:GITHUB_PERSONAL_SETUP_TEMP_ROOT

if ([string]::IsNullOrWhiteSpace($CleanupToken)) {
    Stop-WithError 'Missing temporary-clone cleanup token. Use the run-once command from the README.'
}

if (-not (Test-Path -LiteralPath $CleanupToken -PathType Container)) {
    Stop-WithError "Temporary clone no longer exists: $CleanupToken"
}

$CleanupRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $CleanupToken).Path)
if (-not $CleanupRoot.Equals($SourceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    Stop-WithError 'Cleanup token does not match the setup source directory.'
}

$TemporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
$TemporaryPrefix = $TemporaryRoot + [System.IO.Path]::DirectorySeparatorChar
if (-not $SourceRoot.StartsWith($TemporaryPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    Stop-WithError 'Refusing cleanup outside the system temporary directory.'
}

$SourceName = Split-Path -Leaf $SourceRoot
if (-not $SourceName.StartsWith('github-personal-setup-', [System.StringComparison]::OrdinalIgnoreCase)) {
    Stop-WithError "Refusing cleanup for an unexpected directory name: $SourceName"
}

$Origin = (& git -C $SourceRoot remote get-url origin 2>$null | Out-String).Trim()
$AllowedOrigins = @(
    'https://github.com/protiktoken/github-personal-setup',
    'https://github.com/protiktoken/github-personal-setup.git',
    'git@github.com:protiktoken/github-personal-setup.git',
    'git@github-personal:protiktoken/github-personal-setup.git'
)

if ($Origin -cnotin $AllowedOrigins) {
    Stop-WithError 'Refusing cleanup because the temporary clone has an unexpected origin.'
}

$TargetRepository = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($TargetRepository)) {
    Stop-WithError 'Run the one-time setup command inside the Git repository you want to configure.'
}

$SetupScript = Join-Path $SourceRoot 'windows/setup.ps1'
if (-not (Test-Path -LiteralPath $SetupScript -PathType Leaf)) {
    Stop-WithError "Setup script is missing: $SetupScript"
}

$PowerShellExecutable = (Get-Process -Id $PID).Path
$SetupExitCode = 1

try {
    Write-Host 'Running Windows setup from a disposable clone...'
    & $PowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File $SetupScript @SetupArguments
    $SetupExitCode = $LASTEXITCODE
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    $SetupExitCode = 1
}
finally {
    try {
        if (Test-Path -LiteralPath $SourceRoot) {
            Remove-Item -LiteralPath $SourceRoot -Recurse -Force
        }
    }
    catch {
        [Console]::Error.WriteLine("Warning: Could not remove temporary setup clone: $SourceRoot")
    }
}

exit $SetupExitCode