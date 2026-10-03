#!/usr/bin/env bash
#
# Builds Revisit and installs it on an iPhone connected to this Mac.
#
# Usage:
#   scripts/install.sh                  # the only connected iPhone
#   scripts/install.sh "Jane's iPhone"  # pick one by name or UDID
#
# Signing uses REVISIT_DEVELOPMENT_TEAM and REVISIT_BUNDLE_ID_PREFIX from
# Config/Base.xcconfig, overridden by Config/Secrets.xcconfig or by environment
# variables of the same name:
#   REVISIT_DEVELOPMENT_TEAM=ABCDE12345 REVISIT_BUNDLE_ID_PREFIX=com.jane scripts/install.sh

set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED_DATA=build/DerivedData
APP="$DERIVED_DATA/Build/Products/Debug-iphoneos/Revisit.app"
LOG="$DERIVED_DATA/install.log"

die() { echo "❌ $*" >&2; exit 1; }
step() { echo "▶ $*"; }

# 1. Xcode
command -v xcodebuild >/dev/null 2>&1 || die "找不到 Xcode。請先從 App Store 安裝 Xcode。"
xcodebuild -license check >/dev/null 2>&1 || die "還沒同意 Xcode 授權條款，請執行：sudo xcodebuild -license accept"

if [[ ! -f Config/Secrets.xcconfig ]]; then
  echo "⚠️  沒有 Config/Secrets.xcconfig：3D 重播會改用 Apple 地圖，簽名用 Config/Base.xcconfig 的預設值。"
  echo "   要設定的話：cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig"
fi

# 2. Pick the iPhone
DEVICES_JSON=$(mktemp)
trap 'rm -f "$DEVICES_JSON"' EXIT
xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null 2>&1 \
  || die "無法列出裝置（xcrun devicectl list devices）。"

if ! DEVICE=$(python3 - "$DEVICES_JSON" "${1:-}" 2>&1 <<'PY'
import json, sys

devices = json.load(open(sys.argv[1]))["result"]["devices"]
wanted = sys.argv[2]
phones = [
    d for d in devices
    if d.get("hardwareProperties", {}).get("reality") == "physical"
    and d.get("hardwareProperties", {}).get("platform") == "iOS"
]
if wanted:
    phones = [
        d for d in phones
        if wanted in (d.get("deviceProperties", {}).get("name"), d.get("hardwareProperties", {}).get("udid"), d.get("identifier"))
    ]
if not phones:
    sys.exit("NONE")
if len(phones) > 1:
    sys.exit("MANY:" + ", ".join(d.get("deviceProperties", {}).get("name", "?") for d in phones))
d = phones[0]
print("\t".join([
    d["hardwareProperties"]["udid"],
    d.get("deviceProperties", {}).get("name", "?"),
    str(d.get("deviceProperties", {}).get("developerModeStatus")),
    d.get("connectionProperties", {}).get("pairingState", "?"),
]))
PY
); then
  case "$DEVICE" in
    NONE)   die "找不到 iPhone${1:+「$1」}。請用線接上 Mac，並在手機上按「信任」。" ;;
    MANY:*) die "接著好幾支 iPhone（${DEVICE#MANY:}），請指定一支：scripts/install.sh \"名稱\"" ;;
    *)      die "$DEVICE" ;;
  esac
fi
IFS=$'\t' read -r UDID NAME DEVELOPER_MODE PAIRING <<< "$DEVICE"

[[ "$PAIRING" == "paired" ]] \
  || die "「$NAME」還沒信任這台 Mac：解鎖手機，在跳出的視窗按「信任」。"
[[ "$DEVELOPER_MODE" == "enabled" ]] \
  || die "「$NAME」還沒開啟開發者模式：設定 → 隱私權與安全性 → 開發者模式（要先接過 Xcode 才會出現這個選項）。"

# 3. Build and sign
OVERRIDES=()
[[ -n "${REVISIT_DEVELOPMENT_TEAM:-}" ]] && OVERRIDES+=("REVISIT_DEVELOPMENT_TEAM=$REVISIT_DEVELOPMENT_TEAM")
[[ -n "${REVISIT_BUNDLE_ID_PREFIX:-}" ]] && OVERRIDES+=("REVISIT_BUNDLE_ID_PREFIX=$REVISIT_BUNDLE_ID_PREFIX")

step "編譯並簽名給「$NAME」（第一次會比較久）…"
mkdir -p "$DERIVED_DATA"
if ! xcodebuild -project Revisit.xcodeproj -scheme Revisit -configuration Debug \
    -destination "id=$UDID" -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    ${OVERRIDES[@]+"${OVERRIDES[@]}"} build > "$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u | head -10 >&2 || true
  if grep -qE "Unable to log in|No Account|No profiles|requires a development team" "$LOG"; then
    echo "提示：到 Xcode → Settings → Accounts 登入 Apple ID，再用 Xcode 打開專案、選這支手機按一次 ⌘R 完成第一次簽名。" >&2
  fi
  if grep -qE "is not available|cannot be registered|already in use" "$LOG"; then
    echo "提示：Bundle ID 被別的帳號用掉了，請在 Config/Secrets.xcconfig 設定自己的 REVISIT_BUNDLE_ID_PREFIX。" >&2
  fi
  die "編譯失敗，完整記錄在 $LOG"
fi

# 4. Install and launch
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")

step "安裝到「$NAME」…"
xcrun devicectl device install app --device "$UDID" "$APP" > "$LOG" 2>&1 \
  || die "安裝失敗，記錄在 $LOG"

step "開啟 Revisit…"
if ! LAUNCH=$(xcrun devicectl device process launch --terminate-existing --device "$UDID" "$BUNDLE_ID" 2>&1); then
  if grep -q "Locked" <<< "$LAUNCH"; then
    echo "已安裝。手機目前是鎖定的，解鎖後自己點開 Revisit。"
  elif grep -qiE "not been explicitly trusted|invalid code signature" <<< "$LAUNCH"; then
    echo "已安裝。第一次要在手機上信任開發者：設定 → 一般 → VPN 與裝置管理 → 你的開發者帳號 → 信任。"
  else
    echo "已安裝，但無法自動開啟：$(head -1 <<< "$LAUNCH")"
  fi
fi

echo "✅ 完成"
