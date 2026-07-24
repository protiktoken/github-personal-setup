#!/usr/bin/env bash

set -u

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/github-account-setup.XXXXXX")"
original_path="$PATH"
failures=0
checks=0

trap 'rm -rf "$test_root"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failures=$((failures + 1))
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    checks=$((checks + 1))
    if [[ "$expected" != "$actual" ]]; then
        fail "$message (expected '$expected', got '$actual')"
    fi
}

assert_contains() {
    local value="$1"
    local expected="$2"
    local message="$3"

    checks=$((checks + 1))
    if [[ "$value" != *"$expected"* ]]; then
        fail "$message (missing '$expected')"
    fi
}

create_fake_commands() {
    local fake_bin="$1"

    mkdir -p "$fake_bin"

    cat > "$fake_bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
key_path=""
while (($#)); do
    if [[ "$1" == "-f" ]]; then
        key_path="$2"
        shift 2
    else
        shift
    fi
done
mkdir -p "$(dirname "$key_path")"
printf 'fake-private-key\n' > "$key_path"
printf 'ssh-ed25519 AAAATEST generated@example.com\n' > "$key_path.pub"
EOF

    cat > "$fake_bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'Hi testuser! You have successfully authenticated, but GitHub does not provide shell access.\n' >&2
exit 1
EOF

    cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "user" ]]; then
    printf 'testuser\n'
fi
exit 0
EOF

    for command_name in pbcopy wl-copy xclip; do
        cat > "$fake_bin/$command_name" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
exit 0
EOF
    done

    for command_name in open xdg-open; do
        cat > "$fake_bin/$command_name" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    done

    chmod +x "$fake_bin"/*
}

run_setup() {
    local script_path="$1"
    local repository="$2"
    local home_directory="$3"
    shift 3

    (
        cd "$repository" || exit 1
        HOME="$home_directory" PATH="$home_directory/fake-bin:$original_path" \
            "$script_path" "$@"
    ) 2>&1
}

run_setup_with_input() {
    local script_path="$1"
    local repository="$2"
    local home_directory="$3"
    local input="$4"
    shift 4

    printf '%b' "$input" | (
        cd "$repository" || exit 1
        HOME="$home_directory" PATH="$home_directory/fake-bin:$original_path" \
            "$script_path" "$@"
    ) 2>&1
}

test_successful_setup() {
    local script_path="$1"
    local platform_name="$2"
    local case_root="$test_root/success-$platform_name"
    local repository="$case_root/repository"
    local home_directory="$case_root/home"
    local output
    local status_code

    mkdir -p "$repository" "$home_directory"
    create_fake_commands "$home_directory/fake-bin"
    git -C "$repository" init -q -b main

    output="$(run_setup "$script_path" "$repository" "$home_directory" \
        --yes \
        --username testuser \
        --name 'Test User' \
        --email test@example.com \
        --repo-url https://github.com/testuser/example.git)"
    status_code=$?

    assert_equal "0" "$status_code" "$platform_name setup succeeds"
    assert_equal "Test User" "$(git -C "$repository" config --local user.name 2>/dev/null || true)" "$platform_name stores local name"
    assert_equal "test@example.com" "$(git -C "$repository" config --local user.email 2>/dev/null || true)" "$platform_name stores local email"
    assert_equal "git@github-testuser:testuser/example.git" "$(git -C "$repository" remote get-url origin 2>/dev/null || true)" "$platform_name normalizes origin"
    assert_contains "$(cat "$home_directory/.ssh/config" 2>/dev/null || true)" "Host github-testuser" "$platform_name writes SSH alias"
    assert_contains "$output" "git push -u origin main" "$platform_name prints push command"
}

test_restores_github_account_after_key_creation() {
    local script_path="$1"
    local platform_name="$2"
    local case_root="$test_root/account-switch-$platform_name"
    local repository="$case_root/repository"
    local home_directory="$case_root/home"
    local account_state="$case_root/account-state"
    local status_code

    mkdir -p "$repository" "$home_directory"
    create_fake_commands "$home_directory/fake-bin"
    git -C "$repository" init -q -b main
    printf 'workuser\n' > "$account_state"

    cat > "$home_directory/fake-bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "switch" ]]; then
    shift 2
    while (($#)); do
        if [[ "$1" == "--user" ]]; then
            [[ "$2" != "testuser" || ! -e "$HOME/.ssh/id_ed25519_github_testuser" ]] || exit 2
            printf '%s\n' "$2" > "$FAKE_GH_ACCOUNT_STATE"
            exit 0
        fi
        shift
    done
    exit 0
fi
if [[ "$1" == "api" && "$2" == "user" ]]; then
    cat "$FAKE_GH_ACCOUNT_STATE"
fi
exit 0
EOF
    chmod +x "$home_directory/fake-bin/gh"

    FAKE_GH_ACCOUNT_STATE="$account_state" run_setup \
        "$script_path" "$repository" "$home_directory" \
        --yes \
        --username testuser \
        --name 'Test User' \
        --email test@example.com \
        --repo-url https://github.com/testuser/switched.git >/dev/null
    status_code=$?

    assert_equal "0" "$status_code" "$platform_name temporarily selects the requested GitHub CLI account"
    assert_equal "workuser" "$(cat "$account_state")" "$platform_name restores the previously active GitHub CLI account"
}

test_declined_personal_setup_is_non_mutating() {
    local script_path="$1"
    local platform_name="$2"
    local case_root="$test_root/declined-$platform_name"
    local repository="$case_root/repository"
    local home_directory="$case_root/home"
    local gh_marker="$case_root/gh-called"
    local output
    local status_code

    mkdir -p "$repository" "$home_directory"
    create_fake_commands "$home_directory/fake-bin"
    git -C "$repository" init -q -b main

    cat > "$home_directory/fake-bin/gh" <<'EOF'
#!/usr/bin/env bash
: > "$FAKE_GH_CALLED_MARKER"
exit 0
EOF
    chmod +x "$home_directory/fake-bin/gh"

    output="$(FAKE_GH_CALLED_MARKER="$gh_marker" run_setup_with_input \
        "$script_path" "$repository" "$home_directory" 'n\n' \
        --username testuser \
        --name 'Test User' \
        --email test@example.com \
        --repo-url https://github.com/testuser/declined.git)"
    status_code=$?

    assert_equal "1" "$status_code" "$platform_name stops when personal setup is declined"
    assert_contains "$output" "Configure this repository to use the personal GitHub account 'testuser'?" "$platform_name clearly confirms personal setup"
    assert_equal "no" "$(if [[ -e "$gh_marker" ]]; then printf yes; else printf no; fi)" "$platform_name does not touch GitHub CLI when declined"
    assert_equal "no" "$(if [[ -e "$home_directory/.ssh" ]]; then printf yes; else printf no; fi)" "$platform_name does not touch SSH when declined"
    assert_equal "" "$(git -C "$repository" remote get-url origin 2>/dev/null || true)" "$platform_name does not set origin when declined"
}

test_restores_github_account_when_setup_fails() {
    local script_path="$1"
    local platform_name="$2"
    local case_root="$test_root/restore-failure-$platform_name"
    local repository="$case_root/repository"
    local home_directory="$case_root/home"
    local account_state="$case_root/account-state"
    local status_code

    mkdir -p "$repository" "$home_directory"
    create_fake_commands "$home_directory/fake-bin"
    git -C "$repository" init -q -b main
    printf 'workuser\n' > "$account_state"

    cat > "$home_directory/fake-bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "switch" ]]; then
    printf '%s\n' "$6" > "$FAKE_GH_ACCOUNT_STATE"
elif [[ "$1" == "api" && "$2" == "user" ]]; then
    cat "$FAKE_GH_ACCOUNT_STATE"
fi
exit 0
EOF
    cat > "$home_directory/fake-bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'SSH verification failed\n' >&2
exit 255
EOF
    chmod +x "$home_directory/fake-bin/gh" "$home_directory/fake-bin/ssh"

    FAKE_GH_ACCOUNT_STATE="$account_state" run_setup \
        "$script_path" "$repository" "$home_directory" \
        --yes \
        --username testuser \
        --name 'Test User' \
        --email test@example.com \
        --repo-url https://github.com/testuser/failure.git >/dev/null
    status_code=$?

    assert_equal "1" "$status_code" "$platform_name reports setup failure"
    assert_equal "workuser" "$(cat "$account_state")" "$platform_name restores the GitHub CLI account after failure"
}

test_collaborator_repository_setup() {
    local script_path="$1"
    local platform_name="$2"
    local case_root="$test_root/collaborator-$platform_name"
    local repository="$case_root/repository"
    local home_directory="$case_root/home"
    local status_code

    mkdir -p "$repository" "$home_directory"
    create_fake_commands "$home_directory/fake-bin"
    git -C "$repository" init -q -b main

    run_setup "$script_path" "$repository" "$home_directory" \
        --yes \
        --username testuser \
        --name 'Test User' \
        --email test@example.com \
        --repo-url https://github.com/another-user/example.git >/dev/null
    status_code=$?

    assert_equal "0" "$status_code" "$platform_name configures a collaborator-owned repository"
    assert_equal "Test User" "$(git -C "$repository" config --local user.name 2>/dev/null || true)" "$platform_name stores collaborator identity locally"
    assert_equal "git@github-testuser:another-user/example.git" "$(git -C "$repository" remote get-url origin 2>/dev/null || true)" "$platform_name preserves the collaborator repository owner"
    assert_contains "$(cat "$home_directory/.ssh/config" 2>/dev/null || true)" "Host github-testuser" "$platform_name uses the personal SSH alias for collaboration"
}

test_forced_manual_setup() {
    local script_path="$1"
    local platform_name="$2"
    local case_root="$test_root/manual-$platform_name"
    local repository="$case_root/repository"
    local home_directory="$case_root/home"
    local output
    local status_code

    mkdir -p "$repository" "$home_directory"
    create_fake_commands "$home_directory/fake-bin"
    git -C "$repository" init -q -b main

    output="$(run_setup_with_input "$script_path" "$repository" "$home_directory" '\n' \
        --manual \
        --yes \
        --username testuser \
        --name 'Test User' \
        --email test@example.com \
        --repo-url https://github.com/testuser/manual.git)"
    status_code=$?

    assert_equal "0" "$status_code" "$platform_name forced manual setup succeeds"
    assert_contains "$output" "ssh-ed25519 AAAATEST" "$platform_name manual setup displays only the public key"
    assert_equal "git@github-testuser:testuser/manual.git" "$(git -C "$repository" remote get-url origin 2>/dev/null || true)" "$platform_name manual setup configures origin"
}

test_yes_replaces_origin() {
    local script_path="$1"
    local platform_name="$2"
    local case_root="$test_root/replace-$platform_name"
    local repository="$case_root/repository"
    local home_directory="$case_root/home"

    mkdir -p "$repository" "$home_directory"
    create_fake_commands "$home_directory/fake-bin"
    git -C "$repository" init -q -b main
    git -C "$repository" remote add origin git@example.com:work/example.git

    run_setup "$script_path" "$repository" "$home_directory" \
        --yes \
        --username testuser \
        --name 'Test User' \
        --email test@example.com \
        --repo-url https://github.com/testuser/replaced.git >/dev/null
    status_code=$?

    assert_equal "0" "$status_code" "$platform_name --yes succeeds"
    assert_equal "git@github-testuser:testuser/replaced.git" "$(git -C "$repository" remote get-url origin 2>/dev/null || true)" "$platform_name --yes replaces origin"
}

test_incomplete_key_pair_is_rejected() {
    local script_path="$1"
    local platform_name="$2"
    local case_root="$test_root/incomplete-key-$platform_name"
    local repository="$case_root/repository"
    local home_directory="$case_root/home"
    local status_code

    mkdir -p "$repository" "$home_directory/.ssh"
    create_fake_commands "$home_directory/fake-bin"
    printf 'private-only\n' > "$home_directory/.ssh/id_ed25519_github_testuser"
    git -C "$repository" init -q -b main

    run_setup "$script_path" "$repository" "$home_directory" \
        --yes \
        --username testuser \
        --name 'Test User' \
        --email test@example.com \
        --repo-url https://github.com/testuser/incomplete.git >/dev/null
    status_code=$?

    assert_equal "1" "$status_code" "$platform_name rejects incomplete key pair"
    assert_equal "" "$(git -C "$repository" remote get-url origin 2>/dev/null || true)" "$platform_name incomplete key leaves origin unchanged"
}

test_setup_is_idempotent() {
    local script_path="$1"
    local platform_name="$2"
    local case_root="$test_root/idempotent-$platform_name"
    local repository="$case_root/repository"
    local home_directory="$case_root/home"
    local marker_count

    mkdir -p "$repository" "$home_directory"
    create_fake_commands "$home_directory/fake-bin"
    git -C "$repository" init -q -b main

    for _ in 1 2; do
        run_setup "$script_path" "$repository" "$home_directory" \
            --yes \
            --username testuser \
            --name 'Test User' \
            --email test@example.com \
            --repo-url https://github.com/testuser/idempotent.git >/dev/null
    done

    marker_count="$(grep -c '^# >>> github-personal-setup:github-testuser >>>$' "$home_directory/.ssh/config")"
    assert_equal "1" "$marker_count" "$platform_name keeps one managed SSH block"
}

for platform_name in macos linux; do
    script_path="$project_root/$platform_name/setup.sh"

    if [[ ! -x "$script_path" ]]; then
        fail "$platform_name setup script is missing or not executable"
        continue
    fi

    test_successful_setup "$script_path" "$platform_name"
    test_restores_github_account_after_key_creation "$script_path" "$platform_name"
    test_declined_personal_setup_is_non_mutating "$script_path" "$platform_name"
    test_restores_github_account_when_setup_fails "$script_path" "$platform_name"
    test_collaborator_repository_setup "$script_path" "$platform_name"
    test_forced_manual_setup "$script_path" "$platform_name"
    test_yes_replaces_origin "$script_path" "$platform_name"
    test_incomplete_key_pair_is_rejected "$script_path" "$platform_name"
    test_setup_is_idempotent "$script_path" "$platform_name"
done

if ((failures > 0)); then
    printf '%d of %d checks failed\n' "$failures" "$checks" >&2
    exit 1
fi

printf 'PASS: %d checks\n' "$checks"