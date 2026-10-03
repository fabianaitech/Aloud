#!/usr/bin/env bash
# install.sh — build Aloud once and install it on your iPhone AND Apple Watch.
#
#   ios/install.sh
#
# The watch app ships inside the iPhone app. Installing them from separate
# builds leaves a mismatched pair whose messages can go missing, so this builds
# once and installs both from that one build — never one without the other.
# Both are stamped with the same build number (the git commit count); the
# watch warns if the iPhone's ever differs.
#
# Needs: ios/Local.xcconfig (your team; see Signing.xcconfig), the iPhone
# paired with Xcode (a cable once; Wi-Fi after that), the watch registered in
# Xcode's Device Hub, Developer Mode on both. Keep the iPhone unlocked and the
# watch awake while it installs.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
build_dir="${ALOUD_BUILD_DIR:-$HOME/Library/Caches/aloud-ios-build}"
build_no="$(git rev-list --count HEAD)"

[ -f Local.xcconfig ] || { echo "Create ios/Local.xcconfig first — see ios/Signing.xcconfig." >&2; exit 1; }

# Find the devices by kind, so nothing here is specific to one person's phone.
read -r phone watch < <(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null | python3 -c '
import json, sys
raw = sys.stdin.read()
data = json.loads(raw[raw.index("{"):])
ids = {"iPhone": "-", "appleWatch": "-"}
for d in data.get("result", {}).get("devices", []):
    kind = (d.get("hardwareProperties") or {}).get("deviceType")
    state = (d.get("connectionProperties") or {}).get("tunnelState")
    if kind in ids and ids[kind] == "-" and (d.get("hardwareProperties") or {}).get("reality") == "physical":
        ids[kind] = d.get("identifier")
print(ids["iPhone"], ids["appleWatch"])
')
[ "$phone" != "-" ] || { echo "No iPhone paired with Xcode. Connect it by cable once, then try again." >&2; exit 1; }

echo "==> building Aloud (build $build_no) for iPhone + Apple Watch"
xcodebuild -project Aloud.xcodeproj -scheme Aloud -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$build_dir" \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$build_no" build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
app="$build_dir/Build/Products/Release-iphoneos/Aloud.app"
[ -d "$app/Watch/AloudWatch.app" ] || { echo "The watch app is missing from the build." >&2; exit 1; }

install_on() {   # device-id app-path what hint
  for i in 1 2 3 4; do
    out="$(xcrun devicectl device install app --device "$1" "$2" 2>&1 || true)"
    if grep -q "App installed" <<<"$out"; then echo "    $3: installed"; return 0; fi
    echo "    $3: not reachable ($4) — retrying"; sleep 8
  done
  echo "    $3: FAILED — $(grep -m1 ERROR <<<"$out")" >&2
  return 1
}

echo "==> installing"
install_on "$phone" "$app" "iPhone" "unlock it, same Wi-Fi as this Mac"
if [ "$watch" != "-" ]; then
  install_on "$watch" "$app/Watch/AloudWatch.app" "Apple Watch" "wake it, keep it near the iPhone"
else
  echo "    Apple Watch: none registered in Xcode — skipped"
fi

expires="$(security cms -D -i "$app/embedded.mobileprovision" 2>/dev/null \
  | plutil -extract ExpirationDate raw - 2>/dev/null || true)"
[ -n "$expires" ] && echo "==> signed until $expires (a free Personal Team signs for 7 days; run this again before then)"
