[CmdletBinding()]
param(
    [string]$GitHubUsername,
    [string]$CommitName,
    [string]$CommitEmail,
    [string]$RepositoryUrl,
    [switch]$Manual,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

function Stop-WithError {
    param([string]$Message)

    [Console]::Error.WriteLine("Error: $Message")
    exit 1
}

function Require-Command {
    param(
        [string]$Name,
        [string]$InstallMessage
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Stop-WithError "$Name is required. $InstallMessage"
    }
}

function Read-RequiredValue {
    param(
        [string]$Value,
        [string]$Prompt
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = Read-Host $Prompt
    }

    if ([string]::IsNullOrWhiteSpace($Value)) {
        Stop-WithError "$Prompt cannot be empty."
    }

    return $Value.Trim()
}

function Register-PublicKeyManually {
    param([string]$PublicKeyPath)

    Write-Host ''
    Write-Host 'Add this public key to GitHub:'
    Write-Host ''
    $PublicKey = (Get-Content -Raw $PublicKeyPath).Trim()
    Write-Host $PublicKey
    Write-Host ''

    if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
        Set-Clipboard -Value $PublicKey
        Write-Host 'The public key was copied to the clipboard.'
    }
    else {
        Write-Host 'Copy the public key shown above.'
    }

    try {
        Start-Process 'https://github.com/settings/ssh/new'
    }
    catch {
        Write-Host 'Open https://github.com/settings/ssh/new in a browser.'
    }

    Read-Host 'Add the public key in GitHub, then press Enter to continue' | Out-Null
}

function Write-SshAlias {
    param(
        [string]$SshConfig,
        [string]$HostAlias,
        [string]$KeyPath
    )

    $MarkerStart = "# >>> github-personal-setup:$HostAlias >>>"
    $MarkerEnd = "# <<< github-personal-setup:$HostAlias <<<"
    $OutputLines = [System.Collections.Generic.List[string]]::new()
    $Skipping = $false

    if (Test-Path $SshConfig) {
        foreach ($Line in Get-Content $SshConfig) {
            if ($Line -ceq $MarkerStart) {
                $Skipping = $true
                continue
            }

            if ($Line -ceq $MarkerEnd) {
                $Skipping = $false
                continue
            }

            if (-not $Skipping) {
                $OutputLines.Add($Line)
            }
        }
    }

    while ($OutputLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($OutputLines[$OutputLines.Count - 1])) {
        $OutputLines.RemoveAt($OutputLines.Count - 1)
    }

    if ($OutputLines.Count -gt 0) {
        $OutputLines.Add('')
    }

    $ConfigKeyPath = $KeyPath.Replace('\', '/')
    $OutputLines.Add($MarkerStart)
    $OutputLines.Add("Host $HostAlias")
    $OutputLines.Add('  HostName github.com')
    $OutputLines.Add('  User git')
    $OutputLines.Add("  IdentityFile `"$ConfigKeyPath`"")
    $OutputLines.Add('  IdentitiesOnly yes')
    $OutputLines.Add('  AddKeysToAgent yes')
    $OutputLines.Add($MarkerEnd)

    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($SshConfig, (($OutputLines -join "`n") + "`n"), $Utf8NoBom)

    $WrittenConfig = Get-Content -Raw $SshConfig
    if (-not $WrittenConfig.Contains($MarkerStart) -or -not $WrittenConfig.Contains($MarkerEnd)) {
        Stop-WithError "Could not verify the managed SSH config block in $SshConfig."
    }
}

Require-Command -Name git -InstallMessage 'Install Git for Windows from https://git-scm.com/download/win.'
Require-Command -Name ssh -InstallMessage 'Enable the Windows OpenSSH Client optional feature or install Git for Windows.'
Require-Command -Name ssh-keygen -InstallMessage 'Enable the Windows OpenSSH Client optional feature or install Git for Windows.'

$RepositoryRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    Stop-WithError 'Run this script inside an existing Git repository.'
}

$GitHubUsername = Read-RequiredValue -Value $GitHubUsername -Prompt 'GitHub username'
$CommitName = Read-RequiredValue -Value $CommitName -Prompt 'Git commit name'
$CommitEmail = Read-RequiredValue -Value $CommitEmail -Prompt 'Git commit email'
$RepositoryUrl = Read-RequiredValue -Value $RepositoryUrl -Prompt 'Existing GitHub repository URL'

if ($GitHubUsername.Length -gt 39 -or $GitHubUsername -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$' -or $GitHubUsername.Contains('--')) {
    Stop-WithError 'Enter a valid GitHub username.'
}

if ($CommitEmail -notmatch '^[^\s@]+@[^\s@]+$') {
    Stop-WithError 'Enter a valid Git commit email.'
}

$RepositoryUrl = $RepositoryUrl.TrimEnd('/')
$RepositoryPath = $null

if ($RepositoryUrl -match '^https://github\.com/(.+)$') {
    $RepositoryPath = $Matches[1]
}
elseif ($RepositoryUrl -match '^git@github\.com:(.+)$') {
    $RepositoryPath = $Matches[1]
}
elseif ($RepositoryUrl -match '^ssh://git@github\.com/(.+)$') {
    $RepositoryPath = $Matches[1]
}
elseif ($RepositoryUrl -match '^git@github-[^:]+:(.+)$') {
    $RepositoryPath = $Matches[1]
}
else {
    Stop-WithError 'Enter an HTTPS or SSH URL for github.com.'
}

if ($RepositoryPath.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) {
    $RepositoryPath = $RepositoryPath.Substring(0, $RepositoryPath.Length - 4)
}

$PathParts = $RepositoryPath.Split('/')
if ($PathParts.Count -ne 2) {
    Stop-WithError 'The URL must contain exactly one owner and repository name.'
}

$Owner = $PathParts[0]
$RepositoryName = $PathParts[1]

if (-not $Owner.Equals($GitHubUsername, [System.StringComparison]::OrdinalIgnoreCase)) {
    Stop-WithError "Repository owner '$Owner' does not match GitHub username '$GitHubUsername'."
}

if ($RepositoryName -notmatch '^[A-Za-z0-9._-]+$' -or $RepositoryName -eq '.' -or $RepositoryName -eq '..') {
    Stop-WithError 'The URL contains an invalid repository name.'
}

$UsernameLower = $GitHubUsername.ToLowerInvariant()
$HostAlias = "github-$UsernameLower"
$PersonalRemote = "git@${HostAlias}:${GitHubUsername}/${RepositoryName}.git"
$UserHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$SshDirectory = Join-Path $UserHome '.ssh'
$KeyPath = Join-Path $SshDirectory "id_ed25519_github_$UsernameLower"
$PublicKeyPath = "$KeyPath.pub"
$SshConfig = Join-Path $SshDirectory 'config'
$ExistingRemote = (& git -C $RepositoryRoot remote get-url origin 2>$null | Out-String).Trim()

if ($LASTEXITCODE -ne 0) {
    $ExistingRemote = ''
}

if (-not [string]::IsNullOrWhiteSpace($ExistingRemote) -and $ExistingRemote -cne $PersonalRemote -and -not $Yes) {
    Write-Host "Current origin:  $ExistingRemote"
    Write-Host "Personal origin: $PersonalRemote"
    $Confirmation = Read-Host 'Replace origin? [y/N]'
    if ($Confirmation -notmatch '^(?i:y|yes)$') {
        Stop-WithError 'No changes made.'
    }
}

if (((Test-Path $KeyPath) -and -not (Test-Path $PublicKeyPath)) -or (-not (Test-Path $KeyPath) -and (Test-Path $PublicKeyPath))) {
    Stop-WithError "Incomplete SSH key pair at $KeyPath. Move it aside or restore the missing file."
}

New-Item -ItemType Directory -Path $SshDirectory -Force | Out-Null

if (-not (Test-Path $KeyPath)) {
    Write-Host ''
    Write-Host 'Creating an account-specific SSH key. Enter an optional passphrase directly in ssh-keygen.'
    & ssh-keygen -t ed25519 -C $CommitEmail -f $KeyPath
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError 'ssh-keygen did not create the SSH key.'
    }
}

if (-not (Test-Path $KeyPath) -or -not (Test-Path $PublicKeyPath) -or (Get-Item $KeyPath).Length -eq 0 -or (Get-Item $PublicKeyPath).Length -eq 0) {
    Stop-WithError "SSH key creation failed at $KeyPath."
}

Write-SshAlias -SshConfig $SshConfig -HostAlias $HostAlias -KeyPath $KeyPath

if ($Manual) {
    Register-PublicKeyManually -PublicKeyPath $PublicKeyPath
}
elseif (Get-Command gh -ErrorAction SilentlyContinue) {
    & gh auth status --hostname github.com *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host 'GitHub CLI will open a browser for secure authentication.'
        & gh auth login --hostname github.com --git-protocol ssh --web
        if ($LASTEXITCODE -ne 0) {
            Stop-WithError 'GitHub CLI authentication did not complete.'
        }
    }

    $AuthenticatedUser = (& gh api user --jq .login 2>$null | Out-String).Trim()
    if (-not $AuthenticatedUser.Equals($GitHubUsername, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-WithError "GitHub CLI is authenticated as '$AuthenticatedUser', not '$GitHubUsername'. Run: gh auth switch --hostname github.com --user $GitHubUsername"
    }

    $ComputerName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME.ToLowerInvariant() } else { 'windows' }
    $KeyTitle = "github-personal-setup-$ComputerName-$UsernameLower"
    & gh ssh-key add $PublicKeyPath --title $KeyTitle *> $null
    if ($LASTEXITCODE -ne 0) {
        $PreflightOutput = (& ssh -o StrictHostKeyChecking=accept-new -T $HostAlias 2>&1 | Out-String)
        if ($PreflightOutput -notmatch 'successfully authenticated') {
            Write-Host 'GitHub CLI could not add the key. Continuing with manual public-key registration.'
            Register-PublicKeyManually -PublicKeyPath $PublicKeyPath
        }
    }
}
else {
    Write-Host 'GitHub CLI is not installed.'
    Register-PublicKeyManually -PublicKeyPath $PublicKeyPath
}

$SshOutput = (& ssh -o StrictHostKeyChecking=accept-new -T $HostAlias 2>&1 | Out-String)
if ($SshOutput -notmatch 'successfully authenticated') {
    [Console]::Error.WriteLine($SshOutput.Trim())
    Stop-WithError "GitHub SSH authentication failed for $HostAlias."
}

Push-Location $RepositoryRoot
try {
    & git config --local user.name $CommitName
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError 'Could not set the local Git author name.'
    }

    & git config --local user.email $CommitEmail
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError 'Could not set the local Git author email.'
    }

    if ([string]::IsNullOrWhiteSpace($ExistingRemote)) {
        & git remote add origin $PersonalRemote
    }
    elseif ($ExistingRemote -cne $PersonalRemote) {
        & git remote set-url origin $PersonalRemote
    }

    if ($LASTEXITCODE -ne 0) {
        Stop-WithError 'Could not configure the origin remote.'
    }

    $CurrentBranch = (& git symbolic-ref --quiet --short HEAD 2>$null | Out-String).Trim()

    Write-Host ''
    Write-Host 'Configured personal GitHub access:'
    Write-Host "Repository: $RepositoryRoot"
    Write-Host "Identity:   $CommitName <$CommitEmail>"
    Write-Host "SSH alias:  $HostAlias"
    Write-Host "Origin:     $PersonalRemote"

    if (-not [string]::IsNullOrWhiteSpace($CurrentBranch)) {
        & git rev-parse --verify HEAD *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Host ''
            Write-Host 'Create the first commit, then run:'
        }
        else {
            Write-Host ''
            Write-Host 'To push this branch, run:'
        }
        Write-Host "git push -u origin $CurrentBranch"
    }
}
finally {
    Pop-Location
}