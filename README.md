# VS Code Setup

One safe, predictable VS Code baseline for Linux, macOS and Windows, locally
and over Remote-SSH. Untrusted folders open in restricted mode with automatic
tasks and terminals blocked; telemetry, experiments, the AI features bundled
with GitLens and Atlassian, format-on-save and Git autofetch are off. Anything
that applies to a single repo belongs in that repo's `.vscode/settings.json`,
not here; this `settings.json` is commented section by section and is the
reference for what is set and why.

## Install

```sh
./install.sh                          # symlink + the [core] group
./install.sh --no-ext                 # symlink only
./install.sh --groups core,k8s,ops    # pick groups (or: all)
./install.sh --role sysadmin          # bundle: core,k8s,ops
./install.sh --groups all --profile Cybersec  # into an existing profile
./install.sh --copy                   # copy instead of symlink (Windows)
./install.sh --download --role sysadmin  # VSIX bundle for a machine without internet
./install.sh --offline                # install that bundle there
```

Installing extensions requires VS Code 1.125 or newer; without the `code` CLI,
the default run exits before changing anything (`--no-ext` still installs only
the settings). It symlinks `settings.json` into the user directory
(`~/.config/Code/User/` on Linux, `~/Library/Application Support/Code/User/` on
macOS, `%APPDATA%\Code\User\` on Windows), backing up an existing file as
`settings.json.backup.<date>`. Update a linked config with `git pull --autostash`
here: extensions keep writing their own keys into the file, and a plain `git pull`
stops whenever upstream changed it. To roll back, remove the installed link or
copy and rename the backup in that same user directory to `settings.json`.

Files auto-save one second after you stop typing, so VS Code skips
format-on-save; switch `files.autoSave` to `"onFocusChange"` in a project that
needs it.

**Windows**: run the scripts from Git Bash, not PowerShell. The NTFS symlink
needs Developer Mode on or an elevated shell — without it the install stops at
a preflight check before touching anything and you use `--copy`, which does not
track the repo, so rerun it after every `git pull`. Ansible stays POSIX-only:
the `.venv/bin/python` path applies inside WSL or Remote-SSH, not to a local
Windows workspace.

**WSL and Remote-SSH**: the window reads local user settings, but workspace
extensions run on the remote side and are installed separately — a fresh
distro or host has none. For SSH, uncomment `remote.SSH.defaultExtensions` to
seed every new host, and `remote.downloadExtensionsLocally` to fetch them
locally and push them through the tunnel. For WSL, drive the server CLI:

```sh
srv=$(ls -td ~/.vscode-server/bin/*/bin/code-server | head -1)
"$srv" --install-extension redhat.ansible    # and the rest of the group
sudo apt install shellcheck shfmt
```

A host needs a writable home for `~/.vscode-server` (a few hundred MB) and a
glibc new enough for it. Editing root-owned files needs `sudoedit` — VS Code
cannot elevate on its own.

## Extension groups

`extensions.txt` is split into `[groups]`; `install.sh` installs `[core]`
unless told otherwise. Roles bundle them: `sysadmin` = core,k8s,ops ·
`cybersec` = core,k8s,ops,security · `fullstack` = core,fullstack,ops.

| Group | What |
| --- | --- |
| `core` | Ansible, YAML, Python/Ruff, ShellCheck, shfmt, containers, Terraform, systemd, Jinja2, TOML, EditorConfig, GitLens, Remote-SSH, Dev Containers, markdownlint |
| `k8s` | Kubernetes Tools, OpenShift Connector |
| `ops` | Log highlighting, Rainbow CSV, Error Lens |
| `security` | Hex editor, LLDB, C/C++, PowerShell, Snyk |
| `fullstack` | ESLint, Prettier, Tailwind, Vue, Svelte, Playwright, PostgreSQL, Redis, GitHub PRs and Actions, Bitbucket and Jira, Live Server |
| `windows` | Remote-WSL (Windows-only, so it is not in `core`) |
| `ai` | Claude Code, ChatGPT/Codex, Continue (local Ollama model) |
| `extras` | Spell checker, icon theme |

Add an id under a group, or open a new one with a `[name]` header — then add
its publisher to `extensions.allowed` or VS Code refuses the install. `test.sh`
fails when a publisher is missing, so the mistake surfaces early.

Installs from unlisted publishers are blocked, and updates wait until a release
is 5 days old, except for VS Code's trusted publishers. Marketplace signatures
are verified. The delay covers updates only: a fresh install takes the newest
release, so check its Marketplace date first or pin it as
`publisher.name@1.2.3` in `extensions.txt`, which also marks closed-source and
unmaintained entries. Cloud services need approval on a managed machine:
`security` sends code to Snyk, `ai` to Anthropic and OpenAI — Continue is the
local-only alternative. No role includes `ai`.

For a role-specific extension set, use VS Code **Profiles** (gear icon →
Profiles → New Profile) with *Settings* left shared so this baseline still
applies, then `./install.sh --profile <name>` to fill it. The extension CLI only
accepts an existing profile, and the installer checks it before changing the
settings file.

## External tools

```sh
sudo dnf install ShellCheck shfmt      # Fedora/RHEL
sudo apt install shellcheck shfmt      # Debian/Ubuntu
brew install shellcheck shfmt          # macOS
winget install koalaman.shellcheck     # Windows
winget install mvdan.shfmt
```

`k8s` and `security` also expect `kubectl`, `oc` and `pwsh`. The font is
[MesloLGLDZ Nerd Font](https://www.nerdfonts.com/font-downloads).

`ansible-lint` and `ruff` live in the project's `.venv`, where `settings.json`
points; `bootstrap.sh` creates it — run it in the project, not in this repo.
For a new Ansible or Terraform project use
[project-scaffolds](https://github.com/26zl/project-scaffolds) instead: it lays
out the whole project with hash-locked dependencies, verified collections and
CI, and its generated `.vscode/` files match this configuration.

```sh
cd ~/projects/some-playbooks
/path/to/vscode_config/bootstrap.sh ansible   # or: python | all
```

It fills `.venv` (`uv` when available) with ansible, ansible-lint, yamllint,
ruff, ansible-navigator and ansible-creator — `python` gives ruff and pytest
instead, `all` both — installs `requirements.txt` and any `requirements.yml`
collections, and reports which system binaries are still missing. On a managed
machine point `pip` and `uv` at the internal mirror with `PIP_INDEX_URL` and
`UV_DEFAULT_INDEX`. The named toolset is not version-pinned; use a project
lockfile or the scaffold above for a reproducible shared environment.

## Offline machines

Build the bundle on a machine with internet and Python 3. It lands in
`vsix/<platform>/`, which Git ignores, and each run replaces that platform's
bundle:

```sh
./install.sh --download --role sysadmin      # this machine's OS and VS Code
./install.sh --download --platform win32-x64 --code-version 1.130.0
```

It takes the same groups and roles and adds every dependency. For each
extension it picks the newest release that fits the target VS Code, is not a
pre-release and is at least 5 days old; a pinned `@version` is taken as is.
Each package must match the Marketplace SHA-256 and signature. Copy this folder,
`vsix/` included, to the offline machine, install VS Code of at least that
version there, then run:

```sh
./install.sh --offline
```

VSIX installs skip VS Code's own signature check, so `--offline` first verifies
every package with the `vsce-sign` binary shipped inside VS Code (set
`VSCE_SIGN` if it is not found). A failure stops it before anything changes;
otherwise it links the settings and installs the whole bundle without contacting
the Marketplace. Update checks and schema downloads fail quietly offline; the
*Restricted egress* lines in `settings.json` turn the schema downloads off.

For the project `.venv`, download wheels on a machine with the same OS and
Python version (add `pytest` for `python` or `all`, and `-r requirements.txt`
if the project has one), then point pip and uv at them:

```sh
python3 -m pip download --dest /media/usb/wheels ansible ansible-lint yamllint ruff ansible-navigator ansible-creator
PIP_NO_INDEX=1 PIP_FIND_LINKS=/media/usb/wheels UV_OFFLINE=1 UV_FIND_LINKS=/media/usb/wheels \
  /path/to/vscode_config/bootstrap.sh ansible
```

Collections in a `requirements.yml` still need Galaxy or a local mirror.

## Maintenance

```sh
./test.sh
git add -A && git commit
```

Extensions rewrite the linked `settings.json` at any moment. `install.sh` sets
a Git clean filter in this clone that drops their machine-specific keys whenever
the file is staged, so `git status` can list it as modified while `git add`
stages nothing; `./clean-settings.sh` strips the same keys from the file itself.
`test.sh` and CI reject those keys in the index and home paths anywhere; the
path check runs last, since an extension may rewrite the file in the meantime.
Keep comments in `settings.json` on their own lines, not after values, or the
test complains. `test.sh` and `clean-settings.sh` need a Python 3 (`python3`,
`python`, then `py -3`).

CI runs the self-check on Ubuntu, macOS and Windows, scans history with
gitleaks, lints the workflow with actionlint and checks shell formatting with
shfmt. Dependabot updates the checkout SHA; the gitleaks, actionlint and shfmt
versions and checksums in `ci.yml` must be updated together from their
official release assets. shfmt ships no checksum file; use the SHA-256 digest
GitHub lists for the asset.

Keep Settings Sync **off** (`code --sync off`): the symlink already
distributes the file, Sync would push machine-bound extension state such as
Snyk's CLI path to every machine, and it skips the machine-scoped Ansible and
`python-envs.*` keys. `settingsSync.ignoredSettings` and
`settingsSync.ignoredExtensions` guard anyone who turns it on anyway.

Extension updates install automatically once a release is 5 days old. The
manual Update button bypasses that — check the "Last updated" date first.

## Files

| File | What |
| --- | --- |
| `settings.json` | User settings, commented and sectioned |
| `extensions.txt` | Extensions, split into selectable `[groups]` |
| `install.sh` | Symlinks the config and installs extensions, online or from a VSIX bundle |
| `download-vsix.sh` | Fetches signed VSIX packages and dependencies for `install.sh --download` |
| `test.sh` | Self-check: settings, groups, installer, offline bundle, allow-list, machine paths |
| `clean-settings.sh` | Strips machine-specific keys extensions write into `settings.json` |
| `bootstrap.sh` | Creates a project `.venv` and reports missing system tools |
| `find-python.sh` | Python 3 lookup for the scripts that need one |

Keybindings, color theme and snippets are deliberately left out — personal, or
already shipped by the extensions. MIT licensed.
