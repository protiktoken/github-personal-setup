#!/usr/bin/env bash

set -u

die() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cleanup_root="${GITHUB_PERSONAL_SETUP_TEMP_ROOT:-}"

[[ -n "$cleanup_root" ]] || die "Missing temporary-clone cleanup token. Use the run-once command from the README."
[[ -d "$cleanup_root" ]] || die "Temporary clone no longer exists: $cleanup_root"

cleanup_root="$(cd "$cleanup_root" && pwd -P)"
[[ "$cleanup_root" == "$source_root" ]] || die "Cleanup token does not match the setup source directory."

temporary_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
case "$source_root" in
    "$temporary_root"/*) ;;
    *) die "Refusing cleanup outside the system temporary directory." ;;
esac

source_name="${source_root##*/}"
case "$source_name" in
    github-personal-setup.*) ;;
    *) die "Refusing cleanup for an unexpected directory name: $source_name" ;;
esac

origin="$(git -C "$source_root" remote get-url origin 2>/dev/null || true)"
case "$origin" in
    https://github.com/protiktoken/github-personal-setup|https://github.com/protiktoken/github-personal-setup.git|git@github.com:protiktoken/github-personal-setup.git|git@github-personal:protiktoken/github-personal-setup.git)
        ;;
    *)
        die "Refusing cleanup because the temporary clone has an unexpected origin."
        ;;
esac

cleanup() {
    local exit_code=$?

    trap - EXIT HUP INT TERM
    if [[ -d "$source_root" ]] && ! rm -rf -- "$source_root"; then
        printf 'Warning: Could not remove temporary setup clone: %s\n' "$source_root" >&2
    fi
    exit "$exit_code"
}

trap cleanup EXIT HUP INT TERM

git rev-parse --show-toplevel >/dev/null 2>&1 || die "Run the one-time setup command inside the Git repository you want to configure."

platform="${GITHUB_PERSONAL_SETUP_PLATFORM:-}"
if [[ -z "$platform" ]]; then
    case "$(uname -s)" in
        Darwin) platform="macos" ;;
        Linux) platform="linux" ;;
        *) die "This runner supports macOS and Linux. Use bootstrap/run.ps1 on Windows." ;;
    esac
fi

case "$platform" in
    macos|linux) ;;
    *) die "Unsupported setup platform: $platform" ;;
esac

setup_script="$source_root/$platform/setup.sh"
[[ -f "$setup_script" ]] || die "Setup script is missing: $setup_script"

printf 'Running %s setup from a disposable clone...\n' "$platform"
setup_status=0
bash "$setup_script" "$@" || setup_status=$?
exit "$setup_status"