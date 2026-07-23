$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ScriptUnderTest = Join-Path $ProjectRoot 'windows/setup.ps1'
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("github-personal-setup-{0}" -f [guid]::NewGuid())
$OriginalPath = $env:PATH
$OriginalHome = $env:HOME
$OriginalUserProfile = $env:USERPROFILE
$Failures = 0
$Checks = 0
$CleanupClones = @()

function Assert-Equal {
    param(
        [string]$Expected,
        [string]$Actual,
        [string]$Message
    )

    $script:Checks++
    if ($Expected -cne $Actual) {
        Write-Error "FAIL: $Message (expected '$Expected', got '$Actual')" -ErrorAction Continue
        $script:Failures++
    }
}

function New-FakeCommands {
    param([string]$Directory)

    New-Item -ItemType Directory -Path $Directory -Force | Out-Null

    @'
@echo off
set keypath=
:loop
if "%~1"=="" goto done
if "%~1"=="-f" (
  set keypath=%~2
  shift
)
shift
goto loop
:done
echo fake-private-key>"%keypath%"
echo ssh-ed25519 AAAATEST generated@example.com>"%keypath%.pub"
'@ | Set-Content -Path (Join-Path $Directory 'ssh-keygen.cmd') -Encoding Ascii

    @'
@echo off
echo Hi testuser! You have successfully authenticated, but GitHub does not provide shell access. 1>&2
exit /b 1
'@ | Set-Content -Path (Join-Path $Directory 'ssh.cmd') -Encoding Ascii

    @'
@echo off
if "%~1"=="api" echo testuser
exit /b 0
'@ | Set-Content -Path (Join-Path $Directory 'gh.cmd') -Encoding Ascii
}

try {
    if (-not (Test-Path $ScriptUnderTest)) {
        throw "Setup script is missing: $ScriptUnderTest"
    }

    $Repository = Join-Path $TestRoot 'repository'
    $TestHome = Join-Path $TestRoot 'home'
    $FakeBin = Join-Path $TestHome 'fake-bin'
    New-Item -ItemType Directory -Path $Repository, $TestHome -Force | Out-Null
    New-FakeCommands -Directory $FakeBin

    $env:HOME = $TestHome
    $env:USERPROFILE = $TestHome
    $env:PATH = "$FakeBin;$OriginalPath"

    git -C $Repository init -q -b main
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not initialize the test Git repository.'
    }

    Push-Location $Repository
    try {
        & $ScriptUnderTest `
            -GitHubUsername testuser `
            -CommitName 'Test User' `
            -CommitEmail test@example.com `
            -RepositoryUrl https://github.com/testuser/example.git
    }
    finally {
        Pop-Location
    }

    Assert-Equal 'Test User' (git -C $Repository config --local user.name) 'stores local name'
    Assert-Equal 'test@example.com' (git -C $Repository config --local user.email) 'stores local email'
    Assert-Equal 'git@github-testuser:testuser/example.git' (git -C $Repository remote get-url origin) 'normalizes origin'

    $SshConfig = Get-Content -Raw (Join-Path $TestHome '.ssh/config')
    $script:Checks++
    if ($SshConfig -notmatch 'Host github-testuser') {
        Write-Error 'FAIL: writes account-specific SSH alias' -ErrorAction Continue
        $script:Failures++
    }

    $CleanupRunnerSource = Join-Path $ProjectRoot 'bootstrap/run.ps1'
    if (-not (Test-Path $CleanupRunnerSource)) {
        throw "Cleanup runner is missing: $CleanupRunnerSource"
    }

    $PowerShellExecutable = (Get-Process -Id $PID).Path
    foreach ($CleanupCase in @(
        @{ Name = 'success'; ExitCode = 0 },
        @{ Name = 'failure'; ExitCode = 23 }
    )) {
        $CleanupClone = Join-Path ([System.IO.Path]::GetTempPath()) ("github-personal-setup-{0}" -f [guid]::NewGuid())
        $CleanupClones += $CleanupClone
        $CleanupBootstrapDirectory = Join-Path $CleanupClone 'bootstrap'
        $CleanupWindowsDirectory = Join-Path $CleanupClone 'windows'
        New-Item -ItemType Directory -Path $CleanupBootstrapDirectory, $CleanupWindowsDirectory -Force | Out-Null
        Copy-Item $CleanupRunnerSource (Join-Path $CleanupBootstrapDirectory 'run.ps1')

        @'
[System.IO.File]::WriteAllText($env:CLEANUP_MARKER, (Get-Location).Path)
exit [int]$env:CLEANUP_SETUP_EXIT
'@ | Set-Content -Path (Join-Path $CleanupWindowsDirectory 'setup.ps1') -Encoding UTF8

        git -C $CleanupClone init -q
        git -C $CleanupClone remote add origin https://github.com/protiktoken/github-personal-setup.git

        $CleanupMarker = Join-Path $TestRoot ("cleanup-{0}.marker" -f $CleanupCase.Name)
        $env:GITHUB_PERSONAL_SETUP_TEMP_ROOT = $CleanupClone
        $env:CLEANUP_MARKER = $CleanupMarker
        $env:CLEANUP_SETUP_EXIT = [string]$CleanupCase.ExitCode

        Push-Location $Repository
        try {
            & $PowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File (Join-Path $CleanupBootstrapDirectory 'run.ps1')
            $CleanupStatus = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }

        Assert-Equal ([string]$CleanupCase.ExitCode) ([string]$CleanupStatus) "$($CleanupCase.Name) cleanup preserves setup exit code"
        Assert-Equal 'True' ([string](Test-Path $CleanupMarker)) "$($CleanupCase.Name) cleanup invokes setup"
        Assert-Equal 'False' ([string](Test-Path $CleanupClone)) "$($CleanupCase.Name) cleanup removes the temporary clone"
    }

    $LockedCleanupClone = Join-Path ([System.IO.Path]::GetTempPath()) ("github-personal-setup-{0}" -f [guid]::NewGuid())
    $CleanupClones += $LockedCleanupClone
    $LockedBootstrapDirectory = Join-Path $LockedCleanupClone 'bootstrap'
    $LockedWindowsDirectory = Join-Path $LockedCleanupClone 'windows'
    New-Item -ItemType Directory -Path $LockedBootstrapDirectory, $LockedWindowsDirectory -Force | Out-Null
    Copy-Item $CleanupRunnerSource (Join-Path $LockedBootstrapDirectory 'run.ps1')
    'exit 23' | Set-Content -Path (Join-Path $LockedWindowsDirectory 'setup.ps1') -Encoding UTF8
    git -C $LockedCleanupClone init -q
    git -C $LockedCleanupClone remote add origin https://github.com/protiktoken/github-personal-setup.git

    $LockedFile = Join-Path $LockedCleanupClone 'cleanup.lock'
    $LockStream = [System.IO.File]::Open(
        $LockedFile,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    $env:GITHUB_PERSONAL_SETUP_TEMP_ROOT = $LockedCleanupClone

    Push-Location $Repository
    try {
        & $PowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File (Join-Path $LockedBootstrapDirectory 'run.ps1')
        $LockedCleanupStatus = $LASTEXITCODE
    }
    finally {
        Pop-Location
        $LockStream.Dispose()
    }

    Assert-Equal '23' ([string]$LockedCleanupStatus) 'cleanup failure does not overwrite the setup exit code'
    Assert-Equal 'True' ([string](Test-Path $LockedCleanupClone)) 'failed cleanup leaves the clone for the outer wrapper'

    $ManualClone = Join-Path $TestRoot 'manual-clone'
    $CleanupClones += $ManualClone
    $ManualBootstrapDirectory = Join-Path $ManualClone 'bootstrap'
    New-Item -ItemType Directory -Path $ManualBootstrapDirectory -Force | Out-Null
    Copy-Item $CleanupRunnerSource (Join-Path $ManualBootstrapDirectory 'run.ps1')
    $env:GITHUB_PERSONAL_SETUP_TEMP_ROOT = $ManualClone

    Push-Location $Repository
    try {
        & $PowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ManualBootstrapDirectory 'run.ps1')
        $ManualCloneStatus = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    Assert-Equal '1' ([string]$ManualCloneStatus) 'runner rejects a clone without the temporary name pattern'
    Assert-Equal 'True' ([string](Test-Path $ManualClone)) 'rejected manual clone is never deleted'
}
finally {
    $env:PATH = $OriginalPath
    $env:HOME = $OriginalHome
    $env:USERPROFILE = $OriginalUserProfile
    Remove-Item Env:GITHUB_PERSONAL_SETUP_TEMP_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:CLEANUP_MARKER -ErrorAction SilentlyContinue
    Remove-Item Env:CLEANUP_SETUP_EXIT -ErrorAction SilentlyContinue
    foreach ($CleanupClone in $CleanupClones) {
        Remove-Item -LiteralPath $CleanupClone -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Recurse -Force $TestRoot -ErrorAction SilentlyContinue
}

if ($Failures -gt 0) {
    throw "$Failures of $Checks checks failed"
}

Write-Output "PASS: $Checks checks"