#!/usr/bin/env bash

set -u

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_path="$project_root/windows/setup.ps1"
cleanup_script_path="$project_root/bootstrap/run.ps1"
test_script_path="$project_root/tests/test-windows.ps1"
readme_path="$project_root/README.md"
failures=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failures=$((failures + 1))
}

if [[ ! -f "$script_path" ]]; then
    fail "Windows setup script is missing"
else
    required_patterns=(
        'GitHubUsername'
        'CommitName'
        'CommitEmail'
        'RepositoryUrl'
        '[switch]$Manual'
        'ssh-keygen'
        'gh auth login'
        'https://github.com/settings/ssh/new'
        'successfully authenticated'
        'Could not verify the managed SSH config block'
        'SSH key creation failed'
        'git config --local user.name'
        'git config --local user.email'
        'git remote add origin'
        'git remote set-url origin'
    )

    for pattern in "${required_patterns[@]}"; do
        if ! grep -Fq "$pattern" "$script_path"; then
            fail "Windows setup script is missing contract text: $pattern"
        fi
    done
fi

if [[ ! -f "$cleanup_script_path" ]]; then
    fail "Windows cleanup runner is missing"
else
    cleanup_patterns=(
        'GITHUB_PERSONAL_SETUP_TEMP_ROOT'
        'github-personal-setup-'
        'Remove-Item -LiteralPath $SourceRoot -Recurse -Force'
        'Warning: Could not remove temporary setup clone'
        'windows/setup.ps1'
    )

    for pattern in "${cleanup_patterns[@]}"; do
        if ! grep -Fq "$pattern" "$cleanup_script_path"; then
            fail "Windows cleanup runner is missing contract text: $pattern"
        fi
    done
fi

if ! grep -Fq 'Write-Warning "Could not remove temporary setup clone: $setupDir"' "$readme_path"; then
    fail "Windows run-once documentation does not preserve setup results when fallback cleanup fails"
fi

windows_wrapper_patterns=(
    '& $powerShellExecutable -NoProfile -ExecutionPolicy Bypass -Command {'
    '$setupExitCode = $LASTEXITCODE'
    'exit $setupExitCode'
)

for pattern in "${windows_wrapper_patterns[@]}"; do
    if ! grep -Fq "$pattern" "$readme_path"; then
        fail "Windows run-once documentation does not preserve the setup exit code: $pattern"
    fi
done

if ! grep -Fq 'exit 0' "$test_script_path"; then
    fail "Windows test harness does not explicitly return success"
fi

account_switch_line="$(grep -nF '& gh auth switch --hostname github.com --user $GitHubUsername' "$script_path" | head -n 1 | cut -d: -f1)"
key_generation_line="$(grep -nF '& ssh-keygen -t ed25519' "$script_path" | head -n 1 | cut -d: -f1)"
if [[ -z "$account_switch_line" || -z "$key_generation_line" || "$account_switch_line" -ge "$key_generation_line" ]]; then
    fail "Windows setup does not select the GitHub CLI account before creating the SSH key"
fi

windows_safety_patterns=(
    "Configure this repository to use the personal GitHub account"
    'finally {'
    'gh auth switch --hostname github.com --user $OriginalGitHubCliUser'
)

for pattern in "${windows_safety_patterns[@]}"; do
    if ! grep -Fq "$pattern" "$script_path"; then
        fail "Windows setup does not preserve the personal-account safety contract: $pattern"
    fi
done

if ((failures > 0)); then
    printf '%d Windows contract checks failed\n' "$failures" >&2
    exit 1
fi

printf 'PASS: Windows setup contract\n'