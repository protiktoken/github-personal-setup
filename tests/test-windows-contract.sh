#!/usr/bin/env bash

set -u

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_path="$project_root/windows/setup.ps1"
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

if ((failures > 0)); then
    printf '%d Windows contract checks failed\n' "$failures" >&2
    exit 1
fi

printf 'PASS: Windows setup contract\n'