# Security policy

Cleaner deletes files, so safety problems matter. Examples of what to report: a way to make the app delete something
it must not (personal data, system files), a path-check bypass, a privilege problem with the administrator-password
step, or a way to leak private data through the diagnostic report or the logs.

**Please report privately** through GitHub:
[Report a vulnerability](https://github.com/pavlogrinchenkoo/clean_my_mac_free/security/advisories/new)
(Security tab -> "Report a vulnerability"). Please do not open a public issue for security problems, and do not attach
diagnostic reports or logs to public issues without removing anything private.

This is a small hobby project: I will answer when I can and credit you in the changelog if you want.

## How the app tries to stay safe

See "Safety" in the [README](README.md). In short: it only touches paths from its rules, re-checks every path right
before acting (case-insensitively and after resolving symlinks), never selects personal files automatically, sends
personal files to the Trash, runs `rm` with administrator rights only on `/Library/Caches`, `/Library/Logs` and
installed `.app` bundles, never auto-selects rules from your own `rules.json`, makes no network connections, and runs
with the hardened runtime.
