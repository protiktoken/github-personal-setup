$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ScriptUnderTest = Join-Path $ProjectRoot 'windows/setup.ps1'
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("github-personal-setup-{0}" -f [guid]::NewGuid())
$OriginalPath = $env:PATH
$OriginalHome = $env:HOME
$OriginalUserProfile = $env:USERPROFILE
$Failures = 0
$Checks = 0

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
}
finally {
    $env:PATH = $OriginalPath
    $env:HOME = $OriginalHome
    $env:USERPROFILE = $OriginalUserProfile
    Remove-Item -Recurse -Force $TestRoot -ErrorAction SilentlyContinue
}

if ($Failures -gt 0) {
    throw "$Failures of $Checks checks failed"
}

Write-Output "PASS: $Checks checks"