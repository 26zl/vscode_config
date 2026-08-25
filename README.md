# VS Code Setup

A safe, predictable VS Code base configuration. One setup across every
machine: Linux, macOS and Windows, locally and over Remote-SSH.

## Principles

- **Conservative defaults.** Untrusted folders open in restricted mode, automatic
  tasks and terminals are blocked there, and telemetry, experiments, built-in
  AI, format-on-save and Git autofetch are off. Marketplace update checks remain
  enabled for the delayed extension updates described below.
- **One baseline — project specifics stay in the project.** Anything that
  applies to a single repo (interpreter, test setup, format-on-save for an
  already-formatted codebase) belongs in that repo's own
  `.vscode/settings.json`. That keeps this base identical everywhere.
- **Explicit.** Safety-relevant choices are spelled out in `settings.json`
  with a comment explaining why, even when the value matches the default.

## Contents

| File | What |
| --- | --- |
| `settings.json` | User settings, commented and sectioned |
| `extensions.txt` | Extensions, split into selectable `[groups]` |
| `install.sh` | Symlinks the config and installs extensions (backs up first; `--copy` where symlinks are unavailable) |
| `test.sh` | Self-check: settings and groups, installer behaviour, publisher allow-list, machine-path guard |
| `.editorconfig` | Formatting rules for the files in this repo (shfmt reads it) |
| `bootstrap.sh` | Creates `.venv` for a project and reports missing system tools |
| `clean-settings.sh` | Strips machine-specific keys that extensions write into `settings.json` |
| `.github/workflows/ci.yml` | CI: `test.sh` on Ubuntu, macOS and Windows, secret scan, workflow lint |
| `.github/dependabot.yml` | Keeps the pinned checkout action updated, with a 5-day cooldown |
| `.gitattributes` | Forces LF so the shell scripts survive Windows checkouts |
| `.gitignore` | OS and editor junk |
| `LICENSE` | MIT |

## Installation

```sh
./install.sh                          # symlink + the [core] group
./install.sh --no-ext                 # symlink only
./install.sh --groups core,k8s,ops    # pick groups (or: all)
./install.sh --role sysadmin          # ready-made bundle (see roles)
./install.sh --groups all --profile Cybersec  # into an existing profile
./install.sh --copy                   # copy instead of symlink (see Windows)
```

VS Code 1.123 or newer is required for delayed extension updates. If the
`code` CLI is missing, the default command exits without changing the user
configuration. Use `--no-ext` to request the settings-only mode explicitly.

Files auto-save one second after you stop typing; switch
`files.autoSave` to `"onFocusChange"` if a project needs format-on-save,
which VS Code skips for delayed saves.

An existing `settings.json` is backed up (`settings.json.backup.<date>`),
never overwritten. The symlink means `git pull` in this repo updates the
configuration directly. Roll back by replacing the symlink with the backup:
`mv settings.json.backup.<date> settings.json` in the User directory.

Paths if you prefer doing it manually:

- Linux: `~/.config/Code/User/`
- macOS: `~/Library/Application Support/Code/User/`
- Flatpak: `~/.var/app/com.visualstudio.code/config/Code/User/` (symlink manually)
- VSCodium: `~/.config/VSCodium/User/` (note: Pylance is not available on Open VSX)
- Windows: `%APPDATA%\Code\User\` — `install.sh` handles this from Git Bash;
  see [Windows](#windows) below
- WSL: VS Code uses the Windows-side user settings above; a WSL remote only
  keeps machine-scoped settings

### Windows

The scripts are bash, so run them from **Git Bash** (Git for Windows), not
PowerShell. `install.sh` then writes to `%APPDATA%\Code\User` exactly as it
does elsewhere.

The symlink is a real NTFS one, which Windows only grants with **Developer
Mode** on (Settings → System → For developers) or from an elevated shell.
Without that permission the install stops at a preflight check, before it has
touched anything, and points at the alternative:

```sh
./install.sh --copy    # a real file instead of a link
```

A copy does not track the repo — rerun the command after every `git pull`.
That is why linking stays the default: Git Bash otherwise copies the file *and
still calls it a link*, which would leave the configuration silently detached.
`install.sh` sets `MSYS=winsymlinks:nativestrict` to turn that into an error.

Two more Windows differences, both handled by the scripts:

- The venv layout is `.venv\Scripts\python.exe`, not `.venv/bin/python`;
  `bootstrap.sh` detects whichever one it created.
- `python3` does not exist on a stock install, and the name is a Microsoft
  Store stub when Python was never installed, so `test.sh`, `clean-settings.sh`
  and `bootstrap.sh` fall back to `python`, then `py -3`.

Ansible is the one thing that stays POSIX-only: ansible-core has no Windows
control node, so the `.venv/bin/python` path in `settings.json` applies inside
WSL or a Remote-SSH window, not to a local Windows workspace.

#### WSL

Remote-WSL is in its own `[windows]` group because installing a Windows-only
extension on Linux or macOS would fail the run:

```sh
./install.sh --groups core,k8s,ops,windows
```

A WSL window reads the Windows-side user settings, but **workspace extensions
run on the Linux side and are installed separately** — a fresh distro has none
of them. Seed it without opening a window by driving the VS Code Server CLI:

```sh
srv=$(ls -d ~/.vscode-server/bin/*/bin/code-server | head -1)
"$srv" --install-extension redhat.ansible        # and the rest of the group
```

The Linux tools belong there too, and apt needs root, so run it yourself:

```sh
sudo apt install shellcheck shfmt
```

### Tools the extensions expect

```sh
# Fedora/RHEL
sudo dnf install ShellCheck shfmt
# Debian/Ubuntu
sudo apt install shellcheck shfmt
# macOS
brew install shellcheck shfmt
# Windows
winget install koalaman.shellcheck
winget install mvdan.shfmt
```

The `k8s` and `security` groups expect `kubectl`, `oc` (`openshift-cli`) and
`pwsh` (`powershell`) from your package manager — on Windows that is
`winget install` with `Kubernetes.kubectl`, `RedHat.OpenShift-Client` and
`Microsoft.PowerShell`.

The Linux terminal profile tries common `zsh` paths first and falls back to
`/bin/bash` on minimal servers. Windows uses VS Code's built-in PowerShell
profile — PowerShell 7 when installed, Windows PowerShell otherwise — while
tasks and tools get `powershell.exe`, which every install has.

`ansible-lint` and `ruff` normally live in the project's `.venv`
(`uv pip install ansible-lint ruff`), matching `settings.json` pointing at
`${workspaceFolder}/.venv/bin/python` — `.venv\Scripts\` on Windows.

The font is [MesloLGLDZ Nerd Font](https://www.nerdfonts.com/font-downloads):
`brew install font-meslo-lg-nerd-font` on macOS; on Linux, put the TTF files
in `~/.local/share/fonts/` and run `fc-cache -f`; on Windows,
`scoop bucket add nerd-fonts && scoop install Meslo-NF`, or download the TTFs
and use right-click → Install for all users.

## What is covered

- **Ansible**: language server, `ansible-lint`, FQCN, navigator, execution
  environments via podman (off by default). Lightspeed/cloud AI off.
- **YAML**: Red Hat YAML with schemastore validation; custom tags for Ansible
  `!vault`/`!unsafe` and GitLab CI `!reference` so they don't produce noise.
- **Python**: Pylance (basic type checking) + Ruff as formatter — explicit
  formatting only.
- **Shell**: ShellCheck (with `-x` to follow `source`d files) + shfmt.
- **Web / full stack**: indentation and Prettier overrides for TS/JS/HTML/
  CSS/Vue/Svelte, imports updated on file move, build output kept out of
  search and the file watcher. The extensions are an opt-in group.
- **Security work**: the hardening above is the point — untrusted code
  opens in restricted mode with automatic tasks and terminals blocked, and
  extensions that execute project code (Python, and with it Ansible) stay
  disabled until the folder is trusted. Trust a parent folder once via
  *Workspaces: Manage Workspace Trust* to cover your own projects. Plus
  `.har` and `.sigma` associations, and an opt-in group with a hex editor and
  log/CSV readers.
- **Containers**: Container Tools + Docker DX — the successors to the retired
  Docker extension, with built-in Dockerfile linting (BuildKit/hadolint rules).
- **Other infra**: Terraform, systemd units and Podman Quadlet, Jinja2
  templates, TOML, Markdown lint, `.env` files.
- **Git safety**: prompt before committing straight to `main`/`master`, force
  push off, no autofetch, prune on fetch, 50/72 rulers in the commit box.
- **Extension supply chain**: publisher allow-list (`extensions.allowed`;
  Microsoft's `ms-*` publishers count as the single org key `microsoft`) —
  installs from unlisted publishers are blocked. Updates respect a minimum
  release age of 5 days (`extensions.autoUpdateDelay: 120` hours), except for
  VS Code's trusted publishers such as Microsoft, GitHub and OpenAI. Fully
  manual updates (`"extensions.autoUpdate": "off"`) is the stricter opt-in.
  `extensions.txt` marks which entries are closed source or unmaintained, so
  the trade-off is visible at the point where you pick a group.
- **Remote**: Remote-SSH and Dev Containers. See "Opt-in extras" at the bottom
  of `settings.json` for auto-installing tools on SSH remotes and for podman
  as the container engine.
- **Optional groups** (`./install.sh --groups ...`): `k8s`, `ops`,
  `security`, `fullstack`, `ai` and `extras` — see the group table below.

## Extension groups

`extensions.txt` is split into `[groups]`; `install.sh` installs `[core]`
unless `--groups` says otherwise.

| Group | What |
| --- | --- |
| `core` | Ansible, YAML, Python/Ruff, ShellCheck, shfmt, containers, Terraform, systemd, Jinja2, TOML, EditorConfig, GitLens, Remote-SSH, Dev Containers, markdownlint |
| `k8s` | Kubernetes Tools, OpenShift Connector |
| `ops` | Log highlighting, Rainbow CSV, Error Lens |
| `security` | Hex editor, LLDB, C/C++, PowerShell, Snyk |
| `fullstack` | ESLint, Prettier, Tailwind, Vue, Svelte, Playwright, PostgreSQL, Redis, GitHub PRs and Actions, Live Server |
| `windows` | Remote-WSL (Windows-only, so it is not in `core`) |
| `ai` | Claude Code, ChatGPT/Codex, Continue (local Ollama model) |
| `extras` | Spell checker, icon theme |

Roles are ready-made bundles of those groups, built into `install.sh`:

```sh
./install.sh --role sysadmin    # core,k8s,ops
./install.sh --role cybersec    # core,k8s,ops,security
./install.sh --role fullstack   # core,fullstack,ops
./install.sh --role cybersec --profile Cybersec
```

`--role` and `--groups` are mutually exclusive; use `--groups` for custom
picks, and edit the role table in `install.sh` to change what a role means.

### Adding your own

Add the id under an existing group, or open a new one with a `[name]` header —
no code changes needed. Then add the publisher to `extensions.allowed` in
`settings.json`, or VS Code refuses the install. `test.sh` fails when a
publisher is missing, so the mistake surfaces before you hit it.

### AI

Every AI assistant is opt-in through the `ai` group; no role includes it.
Claude Code and ChatGPT/Codex are cloud services and need an account.
Continue runs against a local model and sends nothing off the machine:
install a runner and pull a model first, e.g.
`brew install ollama && ollama pull qwen2.5-coder`, then point Continue at it
from its own `~/.continue/config.yaml`. `extensions.allowed` already permits
all three publishers.

## Bootstrapping project tools

`bootstrap.sh` runs in the project you are working on, not in this repo:

```sh
cd ~/projects/some-playbooks
/path/to/vscode_config/bootstrap.sh ansible   # or: python | all
```

It creates `.venv` (using `uv` when available, otherwise `python3 -m venv`) and
installs the Python side — plus `requirements.txt` when the project has one —
`ansible`, `ansible-lint`, `yamllint`, `ruff`,
`ansible-navigator` and `ansible-creator` — which is exactly what
`settings.json` expects at `${workspaceFolder}/.venv/bin/python`. When the
project has a `requirements.yml`, its collections and roles are installed with
`ansible-galaxy`. Scaffold new content with `.venv/bin/ansible-creator init`
(playbook projects, collections; the Ansible extension exposes the same
scaffolding in the editor). Finally it lists which system binaries are missing
(`shellcheck`, `shfmt`, `terraform`, `kubectl`, `oc`, `pwsh`); installing those
needs a package manager and root, so the script only reports them.

## Servers and Remote-SSH

Local user settings are reused in Remote-SSH windows and can be overridden per
host. What matters on a server:

- **Most workspace extensions run on the remote host**, while UI extensions
  such as themes remain local. VS Code chooses the location; uncomment
  `remote.SSH.defaultExtensions` to seed every new host with core tooling.
- **Offline or locked-down hosts**: uncomment `remote.downloadExtensionsLocally`
  so extensions are fetched on your machine and pushed through the SSH tunnel.
- **The terminal profile falls back** through zsh paths to bash, so a minimal
  server without zsh still opens a shell.
- **Watcher exclusions matter more remotely**: a large tree on a host with a low
  `fs.inotify.max_user_watches` would otherwise exhaust the limit.
- **Requirements**: a writable home for `~/.vscode-server` (a few hundred MB)
  and a glibc new enough for the VS Code server; very old distributions are not
  supported. Editing root-owned files needs `sudoedit` in the terminal — VS Code
  cannot elevate on its own.

## Adapting the base

The base stays identical everywhere, with telemetry disabled and untrusted
workspace execution restricted. Adapt it in three places:

1. Repo-specific settings go in each repo's `.vscode/settings.json`; they
   override this base only there.
2. For a role-specific set of extensions, use VS Code **Profiles** (gear icon
   → Profiles → New Profile). Leave *Settings* shared with the Default Profile
   so this baseline still applies, give the profile its own *Extensions*, then
   run `./install.sh --profile <name>` to populate it. Profiles cannot be
   created from the CLI, only filled.
3. For a stricter setup, see "Opt-in extras" at the bottom of
   `settings.json` (restricted egress, fully manual updates). Extensions are
   already limited to the publisher allow-list and delayed updates; extend
   `extensions.allowed` deliberately when adopting a new publisher —
   extensions run with your privileges.

## Managed machines

The baseline keeps cloned code from running and built-in AI off. What a
managed environment adds is policy about where data may go:

- **Settings Sync**: leave it off, or sign in with the organisation account.
  The symlink carries the configuration without it.
- **Groups with cloud services** need approval: `security` (Snyk analyses
  code in Snyk's cloud) and `ai` (Claude Code and ChatGPT/Codex send code to
  Anthropic and OpenAI). `fullstack` installs the Atlassian extension, whose
  Rovo Dev agent the baseline disables.
- **Outbound traffic from the core**: the Marketplace for installs and
  updates, and schemastore.org for YAML and TOML schemas. Restricted egress:
  see "Opt-in extras" in `settings.json`.
- **`bootstrap.sh`** installs from PyPI and Ansible Galaxy; point `pip` and
  `uv` at the organisation's mirror with `PIP_INDEX_URL` and
  `UV_DEFAULT_INDEX`.
- **Extension updates**: the 5-day delay is the default;
  `"extensions.autoUpdate": "off"` (opt-in) where change control applies.

## Settings Sync

**Off.** `./install.sh` symlinks `settings.json` into the user directory, so a
`git pull` already distributes the baseline; Sync would be a second, competing
source for the same file. Turn it off on a new machine with:

```sh
code --sync off
```

Two things went wrong while it was on, and the symlink avoids both:

- **Extensions write machine-bound keys into the file.** Snyk stores its
  downloaded CLI path there, which through the symlink lands straight in the
  repo — and Sync would push it to every other machine. `test.sh` rejects such
  paths and `./clean-settings.sh` removes them; keep Snyk in its own profile.

  Because the symlink means a running extension can rewrite `settings.json` at
  any moment, the cleaning and the staging have to be one command — otherwise
  an extension writes its paths back in between the two, and they land in the
  commit:

  ```sh
  ./clean-settings.sh && git add -A && git commit
  ```

  `test.sh` runs its machine-path check last for the same reason.
- **Sync never carries machine-scoped settings.** The extensions mark
  `ansible.python.interpreterPath`, `ansible.validation.lint.path` and the
  `python-envs.*` keys machine-scoped, so a machine that received this baseline
  through Sync alone silently ended up without them. The symlink carries every
  key.

`settingsSync.ignoredSettings` and `settingsSync.ignoredExtensions` stay in
`settings.json` as a guard for anyone who does turn Sync on — they keep the
machine-bound Snyk state and `yaml.schemas` out of the account. With Sync off
they are inert.

If you do enable it, pick **Replace Remote** on a conflict so the repo version
wins, and remember that uninstalling an extension on one machine removes it
everywhere on the next sync.

## Deliberately left out

- **Keybindings** — personal; add a `keybindings.json` to the repo and a
  `link_file keybindings.json` line in `install.sh` if you want it managed.
- **Color theme** — a matter of taste, set per machine/profile.
- **Snippets** — the Ansible and Python extensions ship good ones.

## Maintenance

Edit `settings.json` → run `./test.sh` → commit. The test and cleanup script
need a Python 3 — they try `python3`, then `python`, then `py -3` — and the
test also runs ShellCheck when installed. Keep comments
in `settings.json` on their own lines (not after values), otherwise the test
complains.

Before committing, strip what running extensions have written into
`settings.json` and recheck:

```sh
./clean-settings.sh
./test.sh
git add -A
./test.sh # rechecks both the working tree and staged files
```

`test.sh` and CI reject machine-specific home paths; CI runs the self-check on
Ubuntu, macOS and Windows, scans history with gitleaks and lints the workflow
with actionlint. Dependabot updates the checkout
SHA; the gitleaks and actionlint versions and checksums in `ci.yml` must be
updated together from their official release assets.

Extension updates install automatically once a release is at least 5 days
old. The manual Update button bypasses that delay — check the version's
"Last updated" date first if you use it.
