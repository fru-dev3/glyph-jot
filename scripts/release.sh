#!/bin/zsh
# Build, sign with Developer ID, notarize and publish a release on GitHub: Glyph-Jot-<version>.dmg,
# plus Glyph-Jot.dmg, and Glyph-Dictate.dmg and Jot.dmg so the older stable links
# (releases/latest/download/...) keep working. The dictation engine inside the app is signed the same way.
# Needs a "Developer ID Application" certificate in the keychain, an App Store Connect API key
# for notarization (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH), and the GitHub CLI signed in.
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} # xcodebuild needs Xcode, not the command line tools
: ${ASC_KEY_ID:?set ASC_KEY_ID} ${ASC_ISSUER_ID:?set ASC_ISSUER_ID} ${ASC_KEY_PATH:?set ASC_KEY_PATH}
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
[[ -n $identity ]] || { echo "no Developer ID Application certificate in the keychain"; exit 1; }
team=${identity##*\(}; team=${team%\)}
version=$(awk '/MARKETING_VERSION/{gsub(/"/,"",$2); print $2; exit}' project.yml)

echo "building Glyph Jot $version"
xcodegen generate --quiet
xcodebuild -project Jot.xcodeproj -scheme JotMac -configuration Release -derivedDataPath build -quiet \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" OTHER_CODE_SIGN_FLAGS=--timestamp \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build # no get-task-allow: notarization refuses it
app=build/Build/Products/Release/Jot.app
# The linker's debug map and SwiftPM's baked resource-bundle path carry the build machine's user name and
# home folder. Strip the symbols, blank that path (same length), and sign again, the engine first.
for bin in "$app/Contents/MacOS/Jot" "$app/Contents/Helpers/Glyph Jot Dictation.app/Contents/MacOS/Glyph Jot Dictation"; do
  strip -S -x "$bin"
  python3 - "$bin" <<'PY'
import re, sys
p = sys.argv[1]; b = open(p, "rb").read()
b = re.sub(rb"/Use[r]s/[ -~]*?\.bundle", lambda m: (b"/nonexistent" + b"/" * len(m.group(0)))[:len(m.group(0))], b)
open(p, "wb").write(b)
PY
done
for t in "$app/Contents/Helpers/Glyph Jot Dictation.app" "$app"; do
  codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$identity" "$t"
done
# Nothing of the build machine may be left in the app.
if grep -rqa '/Use[r]s/' "$app"; then echo "source paths left in the app"; grep -rla '/Use[r]s/' "$app"; exit 1; fi
codesign --verify --strict --deep "$app"
engine_sig=$(codesign -dvv "$app/Contents/Helpers/Glyph Jot Dictation.app" 2>&1)
[[ $engine_sig == *"Developer ID Application"* ]] || { echo "the engine is not Developer ID signed"; exit 1; }

echo "making the disk image"
rm -rf dist && mkdir -p dist/stage
cp -R "$app" dist/stage/ && ln -s /Applications dist/stage/Applications
dmg=dist/Glyph-Jot-$version.dmg
hdiutil create -volname "Glyph Jot $version" -srcfolder dist/stage -fs HFS+ -format UDZO -ov "$dmg" -quiet
codesign --sign "$identity" --timestamp "$dmg"

echo "notarizing (a few minutes)"
# Submit, then poll: --wait has hung on Apple's side for an hour. A hung submission can be
# resubmitted by running this again.
id=$(xcrun notarytool submit "$dmg" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" | awk '/^ *id:/ && !s {print $2; s=1}')
[[ -n $id ]] || { echo "notarize: no submission id"; exit 1; }
echo "submission $id"
nstate=""
for _ in {1..90}; do
  nstate=$(xcrun notarytool info "$id" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" 2>&1 | awk '/^ *status:/ && !s {print $2; s=1}')
  [[ $nstate == Accepted || $nstate == Invalid || $nstate == Rejected ]] && break
  sleep 30
done
if [[ $nstate != Accepted ]]; then
  xcrun notarytool log "$id" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" || true
  echo "notarization was not accepted (status: ${nstate:-none})"; exit 1
fi
xcrun stapler staple "$dmg"

echo "checking a downloaded copy passes Gatekeeper"
cp "$dmg" dist/check.dmg
xattr -w com.apple.quarantine "0081;00000000;Safari;" dist/check.dmg
spctl --assess --type open --context context:primary-signature -v dist/check.dmg
rm dist/check.dmg
cp "$dmg" dist/Glyph-Jot.dmg; cp "$dmg" dist/Glyph-Dictate.dmg; cp "$dmg" dist/Jot.dmg

# The version's whole entry in the README (its first line and the indented lines under it).
notes=$(awk -v v="**$version**" 'index($0, "- " v) == 1 {sub(/^- /, ""); out=$0; on=1; next} on && /^  /{sub(/^ +/, ""); out=out " " $0; next} on{exit} END{print out}' README.md)
if gh release view "v$version" >/dev/null 2>&1; then
  gh release upload "v$version" "$dmg" dist/Glyph-Jot.dmg dist/Glyph-Dictate.dmg dist/Jot.dmg --clobber
else
  gh release create "v$version" "$dmg" dist/Glyph-Jot.dmg dist/Glyph-Dictate.dmg dist/Jot.dmg --title "Glyph Jot $version" --notes "${notes:-Glyph Jot $version}"
fi
echo "released: https://github.com/fru-dev3/glyph-jot/releases/tag/v$version"
