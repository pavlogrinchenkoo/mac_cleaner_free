# Changelog

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
