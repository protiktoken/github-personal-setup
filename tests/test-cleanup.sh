#!/usr/bin/env bash

set -u

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="$project_root/bootstrap/run.sh"
readme="$project_root/README.md"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/github-personal-setup-cleanup.XXXXXX")"
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

create_disposable_clone() {
    local name="$1"
    local setup_exit_code="$2"
    local clone_root="$test_root/github-personal-setup.$name"

    mkdir -p "$clone_root/bootstrap" "$clone_root/macos" "$clone_root/linux"
    cp "$runner" "$clone_root/bootstrap/run.sh"
    chmod +x "$clone_root/bootstrap/run.sh"

    cat > "$clone_root/macos/setup.sh" <<EOF
#!/usr/bin/env bash
printf 'ran from %s\n' "\$PWD" > "\$SETUP_MARKER"
exit $setup_exit_code
EOF
    cp "$clone_root/macos/setup.sh" "$clone_root/linux/setup.sh"
    chmod +x "$clone_root/macos/setup.sh" "$clone_root/linux/setup.sh"

    git -C "$clone_root" init -q
    git -C "$clone_root" remote add origin https://github.com/protiktoken/github-personal-setup.git
    printf '%s\n' "$clone_root"
}

create_cancellable_clone() {
    local clone_root="$test_root/github-personal-setup.cancellation"

    mkdir -p "$clone_root/bootstrap" "$clone_root/macos"
    cp "$runner" "$clone_root/bootstrap/run.sh"
    chmod +x "$clone_root/bootstrap/run.sh"

    cat > "$clone_root/macos/setup.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$SETUP_MARKER"
trap 'exit 143' TERM
while :; do :; done
EOF
    chmod +x "$clone_root/macos/setup.sh"

    git -C "$clone_root" init -q
    git -C "$clone_root" remote add origin https://github.com/protiktoken/github-personal-setup.git
    printf '%s\n' "$clone_root"
}

run_disposable_clone() {
    local clone_root="$1"
    local target_repository="$2"
    local marker="$3"

    (
        cd "$target_repository" || exit 1
        GITHUB_PERSONAL_SETUP_TEMP_ROOT="$clone_root" \
        GITHUB_PERSONAL_SETUP_PLATFORM=macos \
        SETUP_MARKER="$marker" \
            bash "$clone_root/bootstrap/run.sh"
    ) >/dev/null 2>&1
}

if [[ ! -x "$runner" ]]; then
    printf 'FAIL: cleanup runner is missing or not executable: %s\n' "$runner" >&2
    exit 1
fi

assert_equal "yes" "$(if grep -Fq 'exit_code=$?' "$readme"; then printf yes; else printf no; fi)" "documented outer cleanup preserves the setup exit status"
assert_equal "yes" "$(if grep -Fq 'Warning: Could not remove temporary setup clone: %s' "$readme"; then printf yes; else printf no; fi)" "documented outer cleanup reports deletion failure"

target_repository="$test_root/target"
mkdir -p "$target_repository"
git -C "$target_repository" init -q -b main

success_clone="$(create_disposable_clone success 0)"
success_marker="$test_root/success.marker"
run_disposable_clone "$success_clone" "$target_repository" "$success_marker"
success_status=$?
assert_equal "0" "$success_status" "successful setup preserves its exit status"
assert_equal "yes" "$(if [[ -f "$success_marker" ]]; then printf yes; else printf no; fi)" "successful setup runs against the target repository"
assert_equal "no" "$(if [[ -e "$success_clone" ]]; then printf yes; else printf no; fi)" "successful setup removes the temporary clone"

failure_clone="$(create_disposable_clone failure 23)"
failure_marker="$test_root/failure.marker"
run_disposable_clone "$failure_clone" "$target_repository" "$failure_marker"
failure_status=$?
assert_equal "23" "$failure_status" "failed setup preserves its exit status"
assert_equal "yes" "$(if [[ -f "$failure_marker" ]]; then printf yes; else printf no; fi)" "failed setup was invoked"
assert_equal "no" "$(if [[ -e "$failure_clone" ]]; then printf yes; else printf no; fi)" "failed setup still removes the temporary clone"

failing_rm_directory="$test_root/failing-rm"
mkdir -p "$failing_rm_directory"
cat > "$failing_rm_directory/rm" <<'EOF'
#!/usr/bin/env bash
exit 55
EOF
chmod +x "$failing_rm_directory/rm"

cleanup_failure_clone="$(create_disposable_clone cleanup-failure 0)"
cleanup_failure_marker="$test_root/cleanup-failure.marker"
(
    cd "$target_repository" || exit 1
    PATH="$failing_rm_directory:$PATH" \
    GITHUB_PERSONAL_SETUP_TEMP_ROOT="$cleanup_failure_clone" \
    GITHUB_PERSONAL_SETUP_PLATFORM=macos \
    SETUP_MARKER="$cleanup_failure_marker" \
        bash "$cleanup_failure_clone/bootstrap/run.sh"
) >/dev/null 2>&1
cleanup_failure_status=$?
assert_equal "0" "$cleanup_failure_status" "cleanup failure does not overwrite the setup exit status"
assert_equal "yes" "$(if [[ -f "$cleanup_failure_marker" ]]; then printf yes; else printf no; fi)" "setup completes before cleanup failure"
assert_equal "yes" "$(if [[ -d "$cleanup_failure_clone" ]]; then printf yes; else printf no; fi)" "failed cleanup leaves the clone for the outer wrapper"

cancellation_clone="$(create_cancellable_clone)"
cancellation_marker="$test_root/cancellation.marker"
(
    cd "$target_repository" || exit 1
    export GITHUB_PERSONAL_SETUP_TEMP_ROOT="$cancellation_clone"
    export GITHUB_PERSONAL_SETUP_PLATFORM=macos
    export SETUP_MARKER="$cancellation_marker"
    exec bash "$cancellation_clone/bootstrap/run.sh"
) >/dev/null 2>&1 &
cancellation_runner_pid=$!

cancellation_deadline=$((SECONDS + 5))
while [[ ! -s "$cancellation_marker" ]] && kill -0 "$cancellation_runner_pid" 2>/dev/null && ((SECONDS < cancellation_deadline)); do
    :
done

if [[ -s "$cancellation_marker" ]]; then
    cancellation_setup_pid="$(cat "$cancellation_marker")"
    kill -TERM "$cancellation_runner_pid" 2>/dev/null || true
    kill -TERM "$cancellation_setup_pid" 2>/dev/null || true
else
    fail "cancellable setup did not start"
    kill -TERM "$cancellation_runner_pid" 2>/dev/null || true
fi

if wait "$cancellation_runner_pid"; then
    cancellation_status=0
else
    cancellation_status=$?
fi

assert_equal "143" "$cancellation_status" "termination preserves the conventional signal exit status"
assert_equal "no" "$(if [[ -e "$cancellation_clone" ]]; then printf yes; else printf no; fi)" "termination removes the temporary clone"

unsafe_clone="$test_root/manual-clone"
mkdir -p "$unsafe_clone/bootstrap" "$unsafe_clone/macos"
cp "$runner" "$unsafe_clone/bootstrap/run.sh"
cp "$project_root/macos/setup.sh" "$unsafe_clone/macos/setup.sh"
git -C "$unsafe_clone" init -q
git -C "$unsafe_clone" remote add origin https://github.com/protiktoken/github-personal-setup.git

(
    cd "$target_repository" || exit 1
    GITHUB_PERSONAL_SETUP_TEMP_ROOT="$unsafe_clone" \
    GITHUB_PERSONAL_SETUP_PLATFORM=macos \
        bash "$unsafe_clone/bootstrap/run.sh"
) >/dev/null 2>&1
unsafe_status=$?
assert_equal "1" "$unsafe_status" "runner rejects a clone without the temporary name pattern"
assert_equal "yes" "$(if [[ -d "$unsafe_clone" ]]; then printf yes; else printf no; fi)" "rejected clone is never deleted"

if ((failures > 0)); then
    printf '%d of %d checks failed\n' "$failures" "$checks" >&2
    exit 1
fi

printf 'PASS: %d cleanup checks\n' "$checks"