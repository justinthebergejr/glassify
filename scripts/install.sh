#!/usr/bin/env bash
# Signs an IPA with your own certificate and installs it on the iPhone plugged into this Mac.
#
#   scripts/install.sh out/Glassify-0.20.0.ipa
#
# Put the certificate details in .signing.env (gitignored):
#   SIGN_P12=/path/to/cert.p12
#   SIGN_PROFILE=/path/to/profile.mobileprovision
#   SIGN_P12_PASSWORD=...
# WIFI=1 installs over Wi-Fi instead of USB (the phone must be paired for wireless sync).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$ROOT/.signing.env" ] && . "$ROOT/.signing.env"
cd "$ROOT"
: "${SIGN_P12:?set SIGN_P12 in .signing.env}" "${SIGN_PROFILE:?set SIGN_PROFILE in .signing.env}" "${SIGN_P12_PASSWORD:?set SIGN_P12_PASSWORD in .signing.env}"

IN="${1:?usage: $0 <ipa>}"
SIGNED="${IN%.ipa}-signed.ipa"

command -v zsign >/dev/null || { echo "missing zsign -> brew install zsign" >&2; exit 1; }
command -v ideviceinstaller >/dev/null || { echo "missing ideviceinstaller -> brew install ideviceinstaller" >&2; exit 1; }

# The bundle id has to equal the App ID of the profile. iOS may well install a mismatched pair, but
# MediaRemote launches the now playing app by its application-identifier entitlement rather than by
# CFBundleIdentifier, so tapping the lock screen card then asks for a bundle that does not exist and
# nothing opens. A wildcard App ID keeps the IPA's own bundle id, but zsign copies the profile's
# entitlements as they are, leaving the application-identifier a literal TEAM.*; sign_wildcard resolves
# it to TEAM.<bundle id> for the app and for each extension, the way Xcode does.
PROFILE_PLIST="$(mktemp)"
security cms -D -i "$SIGN_PROFILE" > "$PROFILE_PLIST" 2>/dev/null
APP_ID="$(plutil -extract Entitlements.application-identifier raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
TEAM="$(plutil -extract TeamIdentifier.0 raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
APP_ID="${APP_ID#*.}"

sign() {  # sign [bundle id]
  echo "==> signing${1:+ as $1}"
  zsign -k "$SIGN_P12" -p "$SIGN_P12_PASSWORD" -m "$SIGN_PROFILE" ${1:+-b "$1"} -z 1 -o "$SIGNED" "$IN" >/dev/null
}

# codesign, so it needs the certificate of SIGN_P12 in the keychain as well.
sign_wildcard() {
  echo "==> signing each bundle under its own id (wildcard App ID)"
  local id work app main b bid
  id="$(openssl pkcs12 -in "$SIGN_P12" -passin pass:"$SIGN_P12_PASSWORD" -nokeys -clcerts -legacy 2>/dev/null \
    | openssl x509 -outform der | shasum | awk '{print toupper($1)}')"
  security find-identity -v -p codesigning | grep -q "$id" \
    || { echo "the certificate in $SIGN_P12 is not in your keychain; import it to sign with a wildcard profile" >&2; exit 1; }
  work="$(mktemp -d)"
  unzip -q "$IN" -d "$work"
  app="$(echo "$work"/Payload/*.app)"
  main="$(plutil -extract CFBundleIdentifier raw -o - "$app/Info.plist")"
  plutil -extract Entitlements xml1 -o "$work/profile.ents" "$PROFILE_PLIST"
  # Innermost first: the dylibs and frameworks, then the extensions, then the app.
  find "$app" \( -name '*.dylib' -o -name '*.framework' \) | awk '{print length, $0}' | sort -rn | cut -d' ' -f2- \
    | while read -r f; do codesign -f -s "$id" "$f" 2>/dev/null; done
  for b in "$app"/PlugIns/*.appex "$app"; do
    [ -d "$b" ] || continue
    bid="$(plutil -extract CFBundleIdentifier raw -o - "$b/Info.plist")"
    cp "$SIGN_PROFILE" "$b/embedded.mobileprovision"
    cp "$work/profile.ents" "$work/bundle.ents"
    plutil -replace application-identifier -string "$TEAM.$bid" "$work/bundle.ents"
    # Its own group first (the default), then the app's, which the app and its extensions share.
    plutil -replace keychain-access-groups -json "[\"$TEAM.$bid\",\"$TEAM.$main\"]" "$work/bundle.ents"
    codesign -f -s "$id" --entitlements "$work/bundle.ents" "$b"
  done
  rm -f "$SIGNED"
  local out; out="$(cd "$(dirname "$SIGNED")" && pwd)/$(basename "$SIGNED")"
  (cd "$work" && zip -qry "$out" Payload)
  rm -rf "$work"
}

if [ -n "$APP_ID" ] && [ "$APP_ID" != "*" ]; then sign "$APP_ID"; else sign_wildcard; fi
rm -f "$PROFILE_PLIST"
echo "==> installing $SIGNED"
ideviceinstaller ${WIFI:+-n} install "$SIGNED" 2>&1 | tail -3
