#!/bin/bash
# Creates a local certificate for signing Cleaner in a SEPARATE keychain (~/.cleaner-signing).
#
# Why: with an ad-hoc signature macOS resets Full Disk Access after every rebuild, because the signature
# is tied to the build hash. With a stable certificate the permission persists across builds.
#
# What it does (and does not):
#   • creates the folder ~/.cleaner-signing with a separate keychain signing.keychain-db;
#   • puts a self-signed certificate "Cleaner Local Signing" there (valid for 10 years);
#   • does NOT touch your main keychain (login), does NOT change the system keychain search list;
#   • does NOT trust the certificate system-wide: it is only needed so the signature is the same from build to build.
# To remove everything: rm -rf ~/.cleaner-signing
#
# Run it once. Running it again breaks nothing. build-app.sh uses this certificate
# automatically if it exists, and otherwise signs ad-hoc, as before.
set -euo pipefail

DIR="$HOME/.cleaner-signing"
KEYCHAIN="$DIR/signing.keychain-db"
NAME="Cleaner Local Signing"
PASS="cleaner-local"   # password for this auxiliary keychain only

if [ -f "$KEYCHAIN" ] && security unlock-keychain -p "$PASS" "$KEYCHAIN" 2>/dev/null \
   && security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Certificate already exists: $KEYCHAIN"
    exit 0
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
cd "$DIR"
rm -f signing.keychain-db key.pem cert.pem identity.p12

openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# The legacy algorithms are needed so that `security import` can read a PKCS12 created by OpenSSL 3.
openssl pkcs12 -export -inkey key.pem -in cert.pem -out identity.p12 -passout "pass:$PASS" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

security create-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"          # no auto-lock
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import identity.p12 -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
# Lets codesign use the key without a password prompt.
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KEYCHAIN" >/dev/null

rm -f key.pem identity.p12
echo "Done: certificate “${NAME}” in ${KEYCHAIN}"
echo
echo "ONE MORE STEP, which YOU perform (the script does not do it): trust the certificate for code signing."
echo "Without it codesign refuses to sign (“no identity found”, status NOT_TRUSTED)."
echo "The command changes trust settings ONLY for your user and ONLY for the “code signing” purpose,"
echo "macOS will show a password dialog:"
echo
echo "  security add-trusted-cert -r trustRoot -p codeSign -k \"$KEYCHAIN\" \"$DIR/cert.pem\""
echo
echo "To revoke trust: security remove-trusted-cert \"$DIR/cert.pem\"   (and rm -rf ~/.cleaner-signing)"
echo "Then: scripts/build-app.sh --install, and grant Full Disk Access one last time."
