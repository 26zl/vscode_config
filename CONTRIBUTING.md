# Contributing

This is a personal VS Code baseline that others are welcome to use and
improve. Changes that fit are fixes, safer defaults and extensions that a
sysadmin, Kubernetes or security role really needs. Keybindings, themes and
snippets stay out, as the README explains.

## Setup

```sh
git clone https://github.com/26zl/vscode_config.git
cd vscode_config
./test.sh
```

`test.sh` needs bash and a Python 3 (`python3`, `python` or `py -3`). It runs
`install.sh` against throwaway home directories only and never touches your
real VS Code configuration. For the same checks CI runs, also install
ShellCheck, shfmt and actionlint (`brew install shellcheck shfmt actionlint`
on macOS; the `dnf`, `apt` and `winget` lines are in the README). On Windows
run everything from Git Bash, not PowerShell.

## Before you open a pull request

```sh
./test.sh
shfmt --diff install.sh test.sh clean-settings.sh clean-activitybar.sh bootstrap.sh find-python.sh download-vsix.sh
actionlint
```

`test.sh` runs ShellCheck as part of the self-check when it is installed.
Formatting follows `.editorconfig` (two spaces, LF), which shfmt reads on its
own. CI (`.github/workflows/ci.yml`) runs `test.sh` on Ubuntu, macOS and
Windows, scans the whole history with gitleaks, checks the formatting with
shfmt and lints the workflow with actionlint; every job must pass.

## What to keep in mind

- `settings.json`: keep comments on their own lines, say why a setting is set,
  and keep machine-specific keys out (`./clean-settings.sh` strips the ones
  extensions write). `test.sh` rejects duplicate keys and home paths.
- `extensions.txt`: add an id under an existing `[group]` or open a new one,
  then add its publisher to `extensions.allowed` in `settings.json`, or VS Code
  refuses the install and `test.sh` fails. Pin closed-source or unmaintained
  entries as `publisher.name@1.2.3`. Nothing that sends code to a cloud
  service goes into a role.
- Scripts are bash that must run on Linux, macOS and Git Bash. Check first,
  change later: fail before anything is written, and back up what you replace.
- The gitleaks, actionlint and shfmt versions in `ci.yml` are updated together
  with their checksums from the official release assets; Dependabot updates
  the checkout action.

## Pull requests and commits

Work on a branch, open a pull request against `main` and say what changed, why,
and how you tested it. Commit messages are short imperative sentences without
a prefix, for example `Open each user's own shell in the terminal on every OS`.
Bugs and questions go in GitHub issues; security problems follow
[SECURITY.md](SECURITY.md).
