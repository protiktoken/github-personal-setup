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

test_invalid_owner_is_non_mutating() {
    local script_path="$1"
    local platform_name="$2"
    local case_root="$test_root/invalid-owner-$platform_name"
    local repository="$case_root/repository"
    local home_directory="$case_root/home"
    local status_code

    mkdir -p "$repository" "$home_directory"
    create_fake_commands "$home_directory/fake-bin"
    git -C "$repository" init -q -b main

    run_setup "$script_path" "$repository" "$home_directory" \
        --username testuser \
        --name 'Test User' \
        --email test@example.com \
        --repo-url https://github.com/another-user/example.git >/dev/null
    status_code=$?

    assert_equal "1" "$status_code" "$platform_name rejects another owner"
    assert_equal "" "$(git -C "$repository" config --local user.name 2>/dev/null || true)" "$platform_name leaves identity unchanged"
    assert_equal "" "$(git -C "$repository" remote get-url origin 2>/dev/null || true)" "$platform_name leaves origin unchanged"
    assert_equal "no" "$(if [[ -e "$home_directory/.ssh/config" ]]; then printf yes; else printf no; fi)" "$platform_name leaves SSH config unchanged"
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
    test_invalid_owner_is_non_mutating "$script_path" "$platform_name"
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