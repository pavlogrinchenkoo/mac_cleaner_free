#!/bin/bash
# Збирає build/Cleaner.dmg (і копію releases/Cleaner-<версія>.dmg), який можна передати другу.
# Використання: scripts/make-dmg.sh [--no-build]
#   --no-build  не перезбирати Cleaner.app, а запакувати наявний build/Cleaner.app
#               (корисно, щоб ad-hoc збірка не скидала Full Disk Access, коли код не змінювався)
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" != "--no-build" ]; then
    scripts/build-app.sh release
elif [ ! -d build/Cleaner.app ]; then
    echo "Немає build/Cleaner.app: запусти без --no-build" >&2
    exit 1
fi

STAGE="build/dmg"
rm -rf "$STAGE" build/Cleaner.dmg
mkdir -p "$STAGE"
cp -R build/Cleaner.app "$STAGE/Cleaner.app"
ln -s /Applications "$STAGE/Applications"

# Інструкція англійською: DMG потрапляє до користувачів з GitHub Releases.
cat > "$STAGE/How to open.txt" <<'TXT'
CLEANER: HOW TO INSTALL AND OPEN

1. Drag Cleaner into the Applications folder.

2. Double-click Cleaner in Applications. macOS will say it cannot verify the
   developer: the app is not signed with a paid Apple Developer ID. This is
   expected for a free open-source app. Click "Done" (NOT "Move to Trash").

3. Right away, open System Settings -> Privacy & Security and scroll ALL THE WAY
   DOWN to the "Security" section. You will see a line about Cleaner with a
   button "Open Anyway". Click it and enter your password.
   The line appears only AFTER you tried to open the app, and only for a few
   minutes. If it is not there, double-click Cleaner again and go back to Settings.
   (Alternative, in Terminal: xattr -dr com.apple.quarantine /Applications/Cleaner.app)
   You only need to do this once.

4. For the Trash, iPhone backups and other protected folders, give Cleaner Full
   Disk Access. The app shows how to do it on first launch. It is optional:
   everything else works without it. After an update macOS may ask again.

LANGUAGE: the interface is in English or Ukrainian. It follows your Mac's
language; switch it any time with the globe button in the sidebar.

HOW TO SEND A DIAGNOSTIC REPORT (helps improve the rules for your apps)
1. Open Cleaner and wait until "Scanning…" at the bottom left disappears.
2. Switch on the "Dry run" toggle at the bottom and press "Check".
   Nothing is deleted.
3. Wait a minute or two while the report is generated.
4. Click "Share…" and send the file to the maintainer privately, or attach it
   to an issue at https://github.com/pavlogrinchenkoo/clean_my_mac_free/issues
   The file contains names of files, folders and apps from your Mac. Read it
   first; issues on GitHub are PUBLIC, so remove anything private before posting.

IMPORTANT: Cleaner deletes files. Personal files, duplicates, iPhone backups and
apps are never selected automatically and are moved to the Trash (you can restore
them). Caches are deleted permanently. Always do a dry run first.
Use at your own risk; the software is provided as is, without warranty (MIT license).

Source code and updates: https://github.com/pavlogrinchenkoo/clean_my_mac_free
TXT

hdiutil create -volname "Cleaner" -srcfolder "$STAGE" -ov -format UDZO build/Cleaner.dmg >/dev/null
rm -rf "$STAGE"

# Копія з номером версії в releases/ (її build/ не чіпає), щоб кожен випуск лишався окремо.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Cleaner.app/Contents/Info.plist)"
mkdir -p releases
cp build/Cleaner.dmg "releases/Cleaner-$VERSION.dmg"
echo "Готово: build/Cleaner.dmg ($(du -h build/Cleaner.dmg | cut -f1)), копія: releases/Cleaner-$VERSION.dmg"
