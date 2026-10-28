# Changelog

## Unreleased

- Code comments, test comments and script messages are now in English (no code changes).

## 1.1.0 — 2026-10-28

- **English interface** alongside Ukrainian. Follows the Mac's language by default; switch with the globe button in the
  sidebar (changing language rescans, because some texts are produced during the scan). Diagnostic reports, the
  command-line tool and the built-in rule descriptions follow the chosen language too.
- The bundle identifier is now `com.pavlogrinchenko.cleaner`. After updating from an earlier build, grant Full Disk Access
  again (saved settings such as project folders start fresh).
- Sizes are formatted by the app (`GB`/`ГБ`, decimal comma in Ukrainian) instead of the system locale.
- MIT license; permission prompts from macOS (Desktop, Documents, Downloads) are localized.
- **Security hardening** after an independent audit:
  - protected-folder checks are case-insensitive and also applied to the path after resolving symlinks;
  - the administrator-rights step re-validates every path right before running `rm` and only accepts
    `/Library/Caches`, `/Library/Logs` and installed `.app` bundles;
  - rules from your own `rules.json` are never auto-selected and cannot request administrator rights;
  - the original of a duplicate is never removed in the same batch as its copy;
  - system folders can no longer be mistaken for an app's leftovers; more package formats are skipped;
  - logs and reports are private (`0700`/`0600`), clean logs use `~` paths, reports hide the user name and
    never name iPhone backups or devices; clearer privacy warnings;
  - hardened runtime; `cleanerctl clean --risk all` no longer includes personal files, backups or apps.
- Tests: translations are checked for completeness and matching format specifiers; no Ukrainian text may leak into
  English mode.

## 1.0.0 — 2026-10-28

First stable release.

- Scan → review → clean flow with groups, sizes and a safe default selection; **dry run** mode that deletes nothing.
- Cleaning groups: app caches (Electron, sandboxed apps, Safari, Chrome), design & media (Adobe, Figma…), large and old
  files, installers, duplicates, iPhone backups, uninstaller with leftovers, projects (`node_modules`, `build`,
  `Pods`…), Xcode and simulators, Android/Gradle, package managers, JetBrains/Android Studio, system logs and caches.
- Personal data is never pre-selected and goes to the Trash; caches are deleted permanently.
- Full Disk Access guide and administrator-password path for system folders.
- Diagnostic report written by every dry run (what was found, selected, blocked and why).
- App icon, universal binary (Apple Silicon + Intel), macOS 14+, DMG installer.
- Verified on a real Mac with Full Disk Access: default selection, administrator password, move to Trash.
- 175 automated tests.

Known limitations: Ukrainian-only interface; not notarized (first launch needs "Open Anyway"); no Time Machine
snapshot cleanup.
