#!/bin/bash
# Builds build/Cleaner.app.
# Usage: scripts/build-app.sh [debug|release] [--install]
#   release    universal binary (Apple Silicon + Intel); debug is for this Mac only
#   --install  also copy the app to /Applications (a stable path works better for Full Disk Access)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="release"
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        debug|release) CONFIG="$arg" ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done
APP="${APP_OUT:-build/Cleaner.app}"   # APP_OUT: build elsewhere without touching build/Cleaner.app

ARCH_FLAGS=()
if [ "$CONFIG" = "release" ]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product Cleaner
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Cleaner" "$APP/Contents/MacOS/Cleaner"
cp "Sources/CleanerCore/rules.json" "$APP/Contents/Resources/rules.json"
cp "Sources/CleanerCore/rules.uk.json" "$APP/Contents/Resources/rules.uk.json"
cp "Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Cleaner</string>
    <key>CFBundleDisplayName</key><string>Cleaner</string>
    <key>CFBundleIdentifier</key><string>com.pavlogrinchenko.cleaner</string>
    <key>CFBundleExecutable</key><string>Cleaner</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>uk</string></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSDesktopFolderUsageDescription</key><string>Cleaner lists big files, duplicates and installers on your Desktop so you can decide what to delete.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>Cleaner looks in Documents for big files, duplicates and project folders (node_modules, build…) that can be removed.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Cleaner lists big files, duplicates and installers in Downloads so you can decide what to delete.</string>
</dict>
</plist>
PLIST

# Texts of the macOS permission prompts (access to Desktop/Documents/Downloads), per system language.
mkdir -p "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/uk.lproj"
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<'STRINGS'
"NSDesktopFolderUsageDescription" = "Cleaner lists big files, duplicates and installers on your Desktop so you can decide what to delete.";
"NSDocumentsFolderUsageDescription" = "Cleaner looks in Documents for big files, duplicates and project folders (node_modules, build…) that can be removed.";
"NSDownloadsFolderUsageDescription" = "Cleaner lists big files, duplicates and installers in Downloads so you can decide what to delete.";
STRINGS
cat > "$APP/Contents/Resources/uk.lproj/InfoPlist.strings" <<'STRINGS'
"NSDesktopFolderUsageDescription" = "Cleaner показує великі файли, дублікати й інсталятори на столі, щоб ти вирішив, що видалити.";
"NSDocumentsFolderUsageDescription" = "Cleaner шукає в Документах великі файли, дублікати й теки проєктів (node_modules, build…), які можна прибрати.";
"NSDownloadsFolderUsageDescription" = "Cleaner показує великі файли, дублікати й інсталятори в Завантаженнях, щоб ти вирішив, що видалити.";
STRINGS

# Signing. If a local certificate exists (scripts/make-signing-identity.sh), sign with it: the designated requirement
# stays stable, so macOS does not reset Full Disk Access after a rebuild. Otherwise ad-hoc, and the permission has to be granted again.
# Hardened runtime (--options runtime): otherwise any process of this user could inject its own code into Cleaner
# via DYLD_INSERT_LIBRARIES, and Cleaner may hold Full Disk Access. No App Sandbox: a cleaner needs access to ~/Library.
SIGN_KEYCHAIN="$HOME/.cleaner-signing/signing.keychain-db"
SIGN_NAME="Cleaner Local Signing"
if [ -f "$SIGN_KEYCHAIN" ] && security unlock-keychain -p "cleaner-local" "$SIGN_KEYCHAIN" 2>/dev/null \
   && security find-identity -v -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null | grep -q "$SIGN_NAME"; then
    codesign --force --options runtime --sign "$SIGN_NAME" --keychain "$SIGN_KEYCHAIN" "$APP"
    SIGN_NOTE="stable signature: Full Disk Access survives a rebuild"
elif [ -f "$SIGN_KEYCHAIN" ]; then
    # The certificate exists, but the system does not trust it yet: codesign refuses to sign with it.
    codesign --force --options runtime --sign - "$APP"
    SIGN_NOTE="ad-hoc signature: certificate not trusted yet (see the end of scripts/make-signing-identity.sh), Full Disk Access will be reset"
else
    codesign --force --options runtime --sign - "$APP"
    SIGN_NOTE="ad-hoc signature: macOS will reset Full Disk Access after this build (see scripts/make-signing-identity.sh)"
fi
echo "Done: $APP ($(lipo -archs "$APP/Contents/MacOS/Cleaner")); $SIGN_NOTE"

if [ "$INSTALL" = 1 ]; then
    rm -rf /Applications/Cleaner.app
    cp -R "$APP" /Applications/Cleaner.app
    echo "Installed: /Applications/Cleaner.app"
fi
