#!/usr/bin/env bash

set -euo pipefail

username=""
commit_name=""
commit_email=""
repository_url=""
assume_yes=false
manual_auth=false
original_github_cli_user=""
restore_github_cli_account=false

usage() {
    cat <<'EOF'
Usage: setup.sh [options]

Configure the current Git repository for a personal GitHub account.

Options:
  --username USER       GitHub username
  --name NAME           Git commit author name
  --email EMAIL         Git commit author email
  --repo-url URL        Existing GitHub repository HTTPS or SSH URL
    --manual              Add the public SSH key through GitHub settings
  --yes                 Replace a different origin without prompting
  -h, --help            Show this help
EOF
}

die() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

prompt_if_empty() {
    local variable_name="$1"
    local prompt="$2"
    local current_value

    eval "current_value=\${$variable_name}"
    if [[ -z "$current_value" ]]; then
        printf '%s: ' "$prompt"
        IFS= read -r current_value || die "No value provided for $prompt."
        printf -v "$variable_name" '%s' "$current_value"
    fi
}

copy_public_key() {
    local public_key_file="$1"

    if command -v wl-copy >/dev/null 2>&1; then
        wl-copy < "$public_key_file"
        printf 'The public key was copied with wl-copy.\n'
    elif command -v xclip >/dev/null 2>&1; then
        xclip -selection clipboard < "$public_key_file"
        printf 'The public key was copied with xclip.\n'
    else
        printf 'Copy the public key shown above.\n'
    fi
}

open_ssh_settings() {
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open 'https://github.com/settings/ssh/new' >/dev/null 2>&1 || true
    fi
}

register_key_manually() {
    local public_key_file="$1"

    printf '\nAdd this public key to GitHub:\n\n'
    cat "$public_key_file"
    printf '\n'
    copy_public_key "$public_key_file"
    open_ssh_settings
    printf 'Open https://github.com/settings/ssh/new, add the key, then press Enter to continue: '
    IFS= read -r _ || die "SSH key registration was not confirmed."
}

prepare_github_cli_account() {
    local requested_username="$1"
    local requested_username_lower="$2"
    local authenticated_user
    local authenticated_user_lower

    original_github_cli_user="$(gh api user --jq .login 2>/dev/null || true)"
    if [[ -n "$original_github_cli_user" && "$(printf '%s' "$original_github_cli_user" | tr '[:upper:]' '[:lower:]')" != "$requested_username_lower" ]]; then
        restore_github_cli_account=true
    fi

    if ! gh auth switch --hostname github.com --user "$requested_username" >/dev/null 2>&1; then
        printf '\nGitHub CLI will open a browser to sign in as %s.\n' "$requested_username"
        gh auth login --hostname github.com --git-protocol ssh --web || die "GitHub CLI authentication did not complete."
    fi

    authenticated_user="$(gh api user --jq .login 2>/dev/null || true)"
    authenticated_user_lower="$(printf '%s' "$authenticated_user" | tr '[:upper:]' '[:lower:]')"
    [[ "$authenticated_user_lower" == "$requested_username_lower" ]] || die "GitHub CLI is authenticated as '${authenticated_user:-unknown}', not '$requested_username'."
}

restore_original_github_cli_account() {
    local exit_code=$?

    trap - EXIT

    if [[ "$restore_github_cli_account" == true ]]; then
        gh auth switch --hostname github.com --user "$original_github_cli_user" >/dev/null 2>&1 ||
            printf 'Warning: Could not restore the previously active GitHub CLI account: %s\n' "$original_github_cli_user" >&2
    fi

    exit "$exit_code"
}

write_ssh_alias() {
    local ssh_config="$1"
    local host_alias="$2"
    local key_path="$3"
    local marker_start="# >>> github-personal-setup:${host_alias} >>>"
    local marker_end="# <<< github-personal-setup:${host_alias} <<<"
    local temporary_file="${ssh_config}.tmp.$$"

    if [[ -f "$ssh_config" ]]; then
        awk -v marker_start="$marker_start" -v marker_end="$marker_end" '
            $0 == marker_start { skipping = 1; next }
            $0 == marker_end { skipping = 0; next }
            !skipping { print }
        ' "$ssh_config" > "$temporary_file"
    else
        : > "$temporary_file"
    fi

    if [[ -s "$temporary_file" ]]; then
        printf '\n' >> "$temporary_file"
    fi

    cat >> "$temporary_file" <<EOF
$marker_start
Host $host_alias
  HostName github.com
  User git
  IdentityFile "$key_path"
  IdentitiesOnly yes
  AddKeysToAgent yes
$marker_end
EOF

    mv "$temporary_file" "$ssh_config"
    chmod 600 "$ssh_config"

    if ! grep -Fqx "$marker_start" "$ssh_config" || ! grep -Fqx "$marker_end" "$ssh_config"; then
        die "Could not verify the managed SSH config block in $ssh_config."
    fi
}

while (($#)); do
    case "$1" in
        --username)
            (($# >= 2)) || die "--username requires a value."
            username="$2"
            shift 2
            ;;
        --name)
            (($# >= 2)) || die "--name requires a value."
            commit_name="$2"
            shift 2
            ;;
        --email)
            (($# >= 2)) || die "--email requires a value."
            commit_email="$2"
            shift 2
            ;;
        --repo-url)
            (($# >= 2)) || die "--repo-url requires a value."
            repository_url="$2"
            shift 2
            ;;
        --yes)
            assume_yes=true
            shift
            ;;
        --manual)
            manual_auth=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

command -v git >/dev/null 2>&1 || die "Git is required. Install it with your distribution package manager."
command -v ssh >/dev/null 2>&1 || die "OpenSSH is required. Install the openssh-client package."
command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen is required. Install the openssh-client package."

repository_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Run this script inside an existing Git repository."
cd "$repository_root"

prompt_if_empty username "GitHub username"
prompt_if_empty commit_name "Git commit name"
prompt_if_empty commit_email "Git commit email"
prompt_if_empty repository_url "Existing GitHub repository URL"

username="$(trim "$username")"
commit_name="$(trim "$commit_name")"
commit_email="$(trim "$commit_email")"
repository_url="$(trim "$repository_url")"

case "$username" in
    ""|-*|*-|*--*|*[!A-Za-z0-9-]*)
        die "Enter a valid GitHub username."
        ;;
esac

if ((${#username} > 39)); then
    die "GitHub usernames cannot exceed 39 characters."
fi

[[ -n "$commit_name" ]] || die "Git commit name cannot be empty."
case "$commit_email" in
    *@*) ;;
    *) die "Enter a valid Git commit email." ;;
esac

while [[ "$repository_url" == */ ]]; do
    repository_url="${repository_url%/}"
done

case "$repository_url" in
    https://github.com/*)
        repository_path="${repository_url#https://github.com/}"
        ;;
    git@github.com:*)
        repository_path="${repository_url#git@github.com:}"
        ;;
    ssh://git@github.com/*)
        repository_path="${repository_url#ssh://git@github.com/}"
        ;;
    git@github-*:*)
        repository_path="${repository_url#*:}"
        ;;
    *)
        die "Enter an HTTPS or SSH URL for github.com."
        ;;
esac

repository_path="${repository_path%.git}"
[[ "$repository_path" == */* ]] || die "The URL must contain an owner and repository name."

owner="${repository_path%%/*}"
repository_name="${repository_path#*/}"
username_lower="$(printf '%s' "$username" | tr '[:upper:]' '[:lower:]')"
owner_lower="$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')"

[[ "$owner_lower" == "$username_lower" ]] || die "Repository owner '$owner' does not match GitHub username '$username'."
case "$repository_name" in
    ""|.|..|*/*|*[!A-Za-z0-9._-]*)
        die "The URL contains an invalid repository name."
        ;;
esac

host_alias="github-${username_lower}"
personal_remote="git@${host_alias}:${username}/${repository_name}.git"
ssh_directory="$HOME/.ssh"
key_path="$ssh_directory/id_ed25519_github_${username_lower}"
ssh_config="$ssh_directory/config"
existing_remote=""

if git remote get-url origin >/dev/null 2>&1; then
    existing_remote="$(git remote get-url origin)"
fi

if [[ "$existing_remote" != "$personal_remote" && "$assume_yes" != true ]]; then
    printf '\nPersonal GitHub setup\n\n'
    printf 'Repository:      %s\n' "$repository_root"
    printf 'GitHub account:  %s\n' "$username"
    printf 'Commit identity: %s <%s>\n' "$commit_name" "$commit_email"
    printf 'New origin:      %s\n\n' "$personal_remote"
    printf "Configure this repository to use the personal GitHub account '%s'? [y/N]: " "$username"
    IFS= read -r confirmation || confirmation=""
    case "$confirmation" in
        y|Y|yes|Yes|YES) ;;
        *) die "No changes made." ;;
    esac
fi

if [[ "$manual_auth" != true ]] && command -v gh >/dev/null 2>&1; then
    trap restore_original_github_cli_account EXIT
    prepare_github_cli_account "$username" "$username_lower"
fi

if [[ -e "$key_path" && ! -e "$key_path.pub" ]] || [[ ! -e "$key_path" && -e "$key_path.pub" ]]; then
    die "Incomplete SSH key pair at $key_path. Move it aside or restore the missing file."
fi

mkdir -p "$ssh_directory"
chmod 700 "$ssh_directory"

if [[ ! -e "$key_path" ]]; then
    printf '\nCreating an account-specific SSH key. Enter an optional passphrase directly in ssh-keygen.\n'
    ssh-keygen -t ed25519 -C "$commit_email" -f "$key_path"
fi

if [[ ! -s "$key_path" || ! -s "$key_path.pub" ]]; then
    die "SSH key creation failed at $key_path."
fi

chmod 600 "$key_path"
chmod 644 "$key_path.pub"

write_ssh_alias "$ssh_config" "$host_alias" "$key_path"

if [[ "$manual_auth" == true ]]; then
    register_key_manually "$key_path.pub"
elif command -v gh >/dev/null 2>&1; then
    key_title="github-personal-setup-$(hostname 2>/dev/null || printf machine)-${username_lower}"
    if ! gh ssh-key add "$key_path.pub" --title "$key_title" >/dev/null 2>&1; then
        printf 'GitHub CLI did not add the key. It may already be registered; verifying SSH next.\n'
    fi
else
    printf '\nGitHub CLI is not installed.\n'
    register_key_manually "$key_path.pub"
fi

ssh_output="$(ssh -o StrictHostKeyChecking=accept-new -T "$host_alias" 2>&1)" || true
if [[ "$ssh_output" != *"successfully authenticated"* ]]; then
    printf '%s\n' "$ssh_output" >&2
    die "GitHub SSH authentication failed for $host_alias."
fi

git config --local user.name "$commit_name"
git config --local user.email "$commit_email"

if [[ -z "$existing_remote" ]]; then
    git remote add origin "$personal_remote"
elif [[ "$existing_remote" != "$personal_remote" ]]; then
    git remote set-url origin "$personal_remote"
fi

current_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

printf '\nConfigured personal GitHub access:\n'
printf 'Repository: %s\n' "$repository_root"
printf 'Identity:   %s <%s>\n' "$commit_name" "$commit_email"
printf 'SSH alias:  %s\n' "$host_alias"
printf 'Origin:     %s\n' "$personal_remote"

if [[ -n "$current_branch" ]]; then
    if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
        printf '\nCreate the first commit, then run:\n'
    else
        printf '\nTo push this branch, run:\n'
    fi
    printf 'git push -u origin %s\n' "$current_branch"
fi