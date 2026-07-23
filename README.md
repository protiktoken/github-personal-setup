# GitHub Personal Setup

Configure a local Git repository to use a personal GitHub account without pasting a password, personal access token, or private SSH key into a script.

The project provides separate native setup scripts for:

- macOS
- Linux
- Windows PowerShell

Each script creates or reuses an account-specific SSH key, configures an SSH host alias, verifies GitHub authentication, and applies the selected identity and remote to the current repository only.

## Before You Start

You need:

1. An existing GitHub account.
2. An existing empty or populated repository under that account.
3. A local Git repository created with `git init` or cloned from elsewhere.
4. Git and OpenSSH installed.

[GitHub CLI](https://cli.github.com/) is optional but recommended. When available, it uses GitHub's official browser login and uploads the generated public SSH key. The scripts never receive the resulting credential. Without GitHub CLI, the script opens GitHub's SSH-key page and asks you to add the public key manually.

When `ssh-keygen` creates a key, it asks for an optional passphrase. Entering a passphrase protects the private key if the file is copied; pressing Enter twice creates the key without one. The passphrase prompt belongs directly to `ssh-keygen`, not these scripts.

## Get The Setup Files

Clone this repository once:

```bash
git clone https://github.com/protiktoken/github-personal-setup.git
```

The target GitHub repository you configure must already exist. These scripts do not create repositories, commit files, or push code.

## macOS

Open Terminal, move into the repository you want to configure, and run:

```bash
cd /path/to/your/repository
bash /path/to/github-personal-setup/macos/setup.sh
```

The script uses `pbcopy` and `open` for the manual SSH-key fallback. Its SSH entry also enables the macOS Keychain integration supplied by Apple's OpenSSH.

## Linux

Open a terminal, move into the repository you want to configure, and run:

```bash
cd /path/to/your/repository
bash /path/to/github-personal-setup/linux/setup.sh
```

For the manual fallback, the script uses `wl-copy` or `xclip` when available and opens GitHub with `xdg-open`.

## Windows PowerShell

Open PowerShell, move into the repository you want to configure, and run:

```powershell
Set-Location C:\path\to\your\repository
powershell -ExecutionPolicy Bypass -File C:\path\to\github-personal-setup\windows\setup.ps1
```

From PowerShell 7, `pwsh` can be used instead of `powershell`:

```powershell
pwsh -File C:\path\to\github-personal-setup\windows\setup.ps1
```

The Windows script uses `Set-Clipboard` and opens the GitHub SSH-key page for the manual fallback.

## Questions The Scripts Ask

Every script asks for:

- GitHub username
- Git commit author name
- Git commit author email
- Existing GitHub repository HTTPS or SSH URL

Accepted repository URL examples:

```text
https://github.com/username/repository.git
git@github.com:username/repository.git
ssh://git@github.com/username/repository.git
```

The URL owner must match the supplied username. The saved remote is normalized to an account-specific SSH alias:

```text
git@github-username:username/repository.git
```

This allows personal and work GitHub accounts to coexist without changing the machine's default Git identity.

## Non-Interactive Arguments

The same values can be supplied as command-line arguments.

macOS or Linux:

```bash
bash setup.sh \
  --username octocat \
  --name "The Octocat" \
  --email octocat@users.noreply.github.com \
  --repo-url https://github.com/octocat/example.git
```

Windows PowerShell:

```powershell
.\setup.ps1 `
  -GitHubUsername octocat `
  -CommitName 'The Octocat' `
  -CommitEmail octocat@users.noreply.github.com `
  -RepositoryUrl https://github.com/octocat/example.git
```

Use `--yes` on macOS/Linux or `-Yes` on Windows only when you intentionally want to replace a different existing `origin` without confirmation.

Use `--manual` on macOS/Linux or `-Manual` on Windows to skip GitHub CLI and register the displayed public key through GitHub settings yourself.

## What Changes

The scripts may create:

```text
~/.ssh/id_ed25519_github_<username>
~/.ssh/id_ed25519_github_<username>.pub
```

They maintain a clearly marked account block in `~/.ssh/config`:

```text
# >>> github-personal-setup:github-<username> >>>
Host github-<username>
  HostName github.com
  User git
  IdentityFile "..."
  IdentitiesOnly yes
# <<< github-personal-setup:github-<username> <<<
```

Inside the current repository, they set:

```text
user.name
user.email
remote.origin.url
```

They do not change the global Git author identity.

## Security Model

- Never paste a GitHub password, personal access token, SSH passphrase, or private key into these scripts.
- A passphrase is entered directly into `ssh-keygen`, which owns that prompt.
- GitHub CLI authentication happens through GitHub's official browser/device flow.
- Only the public key (`.pub`) is uploaded or shown for manual registration.
- A different existing `origin` requires confirmation before replacement.
- Repository identity and remote changes happen only after SSH authentication succeeds.
- Existing SSH configuration is preserved. Each account is maintained inside its own clearly marked block.
- The first SSH verification uses `StrictHostKeyChecking=accept-new`, which accepts and records a previously unseen GitHub host key but rejects a changed key.

Review scripts before running them, especially when using setup automation obtained from someone else.

## After Setup

If the local repository has no commit yet:

```bash
git add .
git commit -m "Initial commit"
git push -u origin main
```

For an existing branch, use the branch-specific push command printed by the script.

Verify the configuration at any time:

```bash
git config --local user.name
git config --local user.email
git remote -v
ssh -T git@github-<username>
```

GitHub's successful SSH test normally exits with status `1` while printing "successfully authenticated" because GitHub does not provide shell access.

## Troubleshooting

### GitHub CLI Is Using The Wrong Account

```bash
gh auth status --hostname github.com
gh auth switch --hostname github.com --user <username>
```

Then rerun the platform setup script.

### Repository Not Found

Confirm that the GitHub repository already exists under the supplied username and that the repository URL is correct.

### SSH Authentication Fails

Confirm that the public key shown by the script appears under [GitHub SSH keys](https://github.com/settings/keys), then rerun:

```bash
ssh -vT git@github-<username>
```

The verbose output shows which key SSH attempted to use.

### Corporate Network Blocks SSH

Some managed networks block outbound SSH on port 22. Try another network or ask the network administrator whether GitHub SSH access is permitted. Do not disable TLS or SSH verification as a workaround.

## Tests

On macOS or Linux:

```bash
bash tests/run.sh
```

On Windows PowerShell:

```powershell
.\tests\test-windows.ps1
```

Tests use temporary homes, fake SSH keys, and stubbed GitHub commands. They do not access a real GitHub account or modify the user's SSH configuration.