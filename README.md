# Cleaner — a free, careful disk cleaner for macOS

Cleaner finds caches, logs, leftovers, build folders and big forgotten files that are safe to remove,
shows them in groups with sizes, and lets **you** decide what goes. It is free and open source: an alternative to
paid cleaners when you want to see exactly what is about to be deleted.

- Scan → review → clean. Nothing is deleted until you press the button and confirm.
- A **dry run** mode shows exactly what would happen and deletes nothing.
- Personal files are never selected for you, and are moved to the Trash (recoverable), not erased.
- Built for designers and developers alike: Adobe, Figma, Affinity, Pixelmator, Xcode, Android, `node_modules`, and more.

> **Language:** the app interface is currently in **Ukrainian**. Button labels are given in this guide in
> parentheses so you can find them. English localization is planned.

## Download

1. Go to the [**latest release**](https://github.com/pavlogrinchenkoo/clean_my_mac_free/releases/latest).
2. Download **`Cleaner-<version>.dmg`**.

Requires **macOS 14 (Sonoma) or newer**. Runs natively on Apple Silicon and Intel.

## Install and first launch

1. Open the DMG and drag **Cleaner** into **Applications**.
2. Double-click Cleaner in Applications. macOS will say it cannot verify the developer. Click **Done**
   (not "Move to Trash"). This happens because the app is not signed with a paid Apple Developer ID.
3. Immediately open **System Settings → Privacy & Security** and scroll **all the way down** to the **Security**
   section. You will see a line about Cleaner with a button **Open Anyway**. Click it and enter your password.
   - The button appears only **after** you tried to open the app, and only for a few minutes. If it is not there,
     double-click Cleaner again and go back to Settings.
   - Alternative, in Terminal: `xattr -dr com.apple.quarantine /Applications/Cleaner.app`
4. Cleaner will offer to guide you through **Full Disk Access** (see below). It is optional but recommended.

You only need to do this once.

## Permissions

| Permission | Why | Required? |
|---|---|---|
| **Full Disk Access** | To see the Trash, iPhone backups, Mail downloads and protected folders. macOS does not let apps enable it themselves, so Cleaner opens the right Settings pane and shows the app in Finder to drag in. It takes effect after a restart of the app (the "Перезапустити" button). | Optional. Everything else works without it. |
| **Administrator password** | Only for system folders (`/Library/Caches`, `/Library/Logs`) and apps installed by an administrator. These items are **off by default**; the password prompt appears only if you select them and confirm. | Optional |
| **Documents / Desktop / Downloads** | macOS may ask once, because the app lists big files, duplicates and installers there. | Optional |

> Because the app is not signed with a paid certificate, macOS may reset Full Disk Access after you install an
> update. Just grant it again.

## How to use

1. Open Cleaner and wait for the scan to finish (the "Сканую…" label at the bottom left disappears; groups with nothing to clean are hidden).
2. Click a group in the sidebar to see its items with sizes and age. Safe caches are pre-selected; everything
   risky or personal is not.
3. Switch on **Dry run** («Пробний запуск») at the bottom and press **Check** («Перевірити»). Nothing is deleted:
   you get a report of what would be removed.
4. Switch the dry run off, press **Clean** («Очистити…») and confirm. The summary shows what was freed and what
   went to the Trash. Space from the Trash is released when you empty it.

The checkbox next to a group only selects the **recommended** items. It can never select personal files,
duplicates, iPhone backups, apps or the Trash with one click: those you tick one by one.

## What it can clean

| Group | Examples |
|---|---|
| App caches | Electron apps (Figma, Discord, Slack…), sandboxed apps (Affinity, Pixelmator…), Safari, Chrome, Telegram media cache |
| Design & media | Adobe Media Cache and Peak Files; Photoshop, Lightroom, Illustrator, Camera Raw caches; old Adobe versions (shown as a hint) |
| Files & copies | Large and old files by category, installers in Downloads/Desktop, **duplicates**, iPhone backups |
| Uninstaller | Apps from /Applications together with their leftovers in `~/Library` |
| Projects | `node_modules`, `build`, `Pods`, `.dart_tool`… per project; only projects untouched for 30+ days are pre-selected |
| Xcode & simulators | DerivedData, DeviceSupport, Archives, simulator runtimes and devices (off by default) |
| Android & Gradle | Gradle caches and wrappers, emulators (AVD) and NDK versions (off by default) |
| Package managers | npm, Yarn, CocoaPods, Swift Package Manager, Homebrew, pip and other build caches |
| IDEs | Caches and settings of old JetBrains / Android Studio versions (the newest is always kept) |
| System | App logs, system caches (password), Apple service caches, Mail downloads, iPhone firmware (`.ipsw`), Trash |

Groups that do not apply to your Mac are not shown: a designer will not see Xcode, a developer will not see Adobe.

## Safety

Cleaner is conservative by design.

- It only touches paths listed in its rules, never arbitrary ones, and re-checks every path right before acting.
- It refuses your home folder, Documents, Desktop, Downloads, Mail, Messages, keychains, `.ssh`, iCloud Drive and
  anything outside your home folder (except the two system cache/log folders above, with your password).
- **Personal files, duplicates, iPhone backups and uninstalled apps go to the Trash**, are never pre-selected,
  and a duplicate is only removed while its original is still in place: your last copy is never touched.
- **Caches are deleted permanently.** They are things apps rebuild by themselves, which is why they are the
  default selection. That is also why the dry run exists.
- It skips caches of apps that are running right now (Xcode, Chrome, Figma, Android Studio, Gradle daemon,
  simulators…).
- Projects: only well-known folders (`node_modules`, `build`…) inside project folders you added yourself, and only
  next to real project files (`package.json`, `Podfile`, `*.xcodeproj`…).
- A symlink is removed itself, never the thing it points to.
- Every real clean writes a log to `~/Library/Application Support/Cleaner/logs/`.

**Use at your own risk and always start with a dry run.** The software is provided as is, without warranty.

## Help improve the rules: send a diagnostic report

Different Macs have different apps, and Cleaner's rules grow from real data. Every dry run saves a report to
`~/Library/Application Support/Cleaner/logs/dryrun-<date>.txt` and offers **Share…** («Поділитися…»). The report
contains: app and macOS versions, free space, everything found, what was selected automatically or by you, what was
blocked and why, your installed apps, and a map of the biggest folders in `~/Library` and your user folders.

It contains **file and app names from your Mac**, so please read it before sending. If you want to help, attach it
to an [issue](https://github.com/pavlogrinchenkoo/clean_my_mac_free/issues).

## Build from source

Requires macOS 14+ and a Swift 6 toolchain (developed with Xcode 26).

```bash
swift test                       # run the tests
scripts/build-app.sh             # build/Cleaner.app (universal)
scripts/make-dmg.sh              # build/Cleaner.dmg and releases/Cleaner-<version>.dmg
swift run cleanerctl scan        # command-line version: list what can be cleaned
swift run cleanerctl clean       # dry run; add --yes to really clean the default selection
swift run cleanerctl diagnose    # write the diagnostic report
scripts/selftest.sh              # headless self-check on your Mac (dry run only, deletes nothing)
```

### Custom rules

Add `~/Library/Application Support/Cleaner/rules.json` in the same format as the built-in
[`rules.json`](Sources/CleanerCore/rules.json). A rule with the same `id` overrides the built-in one. All paths still
pass through the safety guards.

A Ukrainian developer guide with architecture and design notes is in [README.uk.md](README.uk.md).

## Status

Version 1.0.0. Known limitations: the interface is Ukrainian only; the app is not notarized (hence the first-launch
steps above); local Time Machine snapshots and `brew cleanup` are not handled yet. See [CHANGELOG.md](CHANGELOG.md).
