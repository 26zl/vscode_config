# Security policy

## Reporting a vulnerability

Report security problems privately through GitHub:
[Report a vulnerability](https://github.com/26zl/vscode_config/security/advisories/new)
(the Security tab of this repository). Do not open a public issue for anything
that could be exploited before it is fixed. Expect a first reply within seven
days. The fix lands on `main` as an ordinary commit, and the advisory is
published once it is in.

Use an ordinary [issue](https://github.com/26zl/vscode_config/issues) for
things that are not sensitive: a wrong setting, an extension that does not
belong in a group, a check that fails.

## What counts

The scripts promise to verify before they install and to stop before they
change anything when a check fails. A private report is right when that
promise breaks, for example:

- `install.sh`, `download-vsix.sh` or `install.sh --offline` accepting a
  package whose SHA-256 or Marketplace signature does not match, or touching
  the real user directory before a preflight check has failed.
- A way past the publisher allow-list (`extensions.allowed`), the 5-day update
  delay or the restricted-mode defaults in `settings.json`.
- `clean-settings.sh` or `clean-activitybar.sh` leaving data behind that the
  README says is removed, or corrupting the file or database they edit.
- A default in `settings.json` that sends code or telemetry somewhere the
  README says it does not.

Vulnerabilities in VS Code itself or in a listed extension belong with their
maintainers; this repository only picks which extensions to install and how.

## Supported versions

There are no releases. Only the current `main` branch is supported; update a
linked clone with `git pull --autostash` to pick up fixes.
