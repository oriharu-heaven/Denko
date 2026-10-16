#!/bin/zsh
# 配布用ビルド: Developer ID 署名 → 公証（notarization）→ DMG 作成 →（任意）GitHub Release
#
# 事前準備（初回だけ）: RELEASE.md の「1. 準備」を参照
#
#   TEAM_ID=XXXXXXXXXX ./scripts/release.sh 1.0.0            # DMG を作るまで
#   TEAM_ID=XXXXXXXXXX ./scripts/release.sh 1.0.0 --publish  # GitHub Release も作る
#   TEAM_ID=XXXXXXXXXX ./scripts/release.sh 1.1.0-beta.1 --publish --prerelease  # ベータ配布
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?バージョンを指定してください（例: 1.0.0）}"
shift
PUBLISH=false; PRERELEASE=""
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=true ;;
    --prerelease) PRERELEASE="--prerelease" ;;
  esac
done

APP_NAME="Denko"
TEAM_ID="${TEAM_ID:?TEAM_ID を指定してください（Apple Developer のチーム ID）}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"
BUILD="${TMPDIR:-/tmp}/$APP_NAME-release"
OUT="build/release"
ARCHIVE="$BUILD/$APP_NAME.xcarchive"
EXPORT="$BUILD/export"
DMG="$BUILD/$APP_NAME-$VERSION.dmg"
SPM="$BUILD/spm"
REPO="${GITHUB_REPO:-oriharu-heaven/Denko}"

rm -rf "$BUILD"
mkdir -p "$BUILD"
xcodegen generate >/dev/null

echo "▶ アーカイブ（$VERSION）"
xcodebuild archive -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -archivePath "$ARCHIVE" -clonedSourcePackagesDirPath "$SPM" \
  MARKETING_VERSION="${VERSION%%-*}" CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" OTHER_CODE_SIGN_FLAGS="--timestamp" \
  | grep -E "error:|ARCHIVE" || true

echo "▶ 書き出し（Developer ID）"
cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$BUILD/ExportOptions.plist" \
  -exportPath "$EXPORT" | grep -E "error:|EXPORT" || true

echo "▶ DMG 作成"
STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
cp -R "$EXPORT/$APP_NAME.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "Developer ID Application" --timestamp "$DMG"

echo "▶ 公証（数分かかります）"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

echo "▶ Sparkle の appcast.xml 作成"
# 署名にはキーチェーンの EdDSA 秘密鍵（generate_keys で作成済み）を使う。
# フィードは最新リリースに添付するので、項目はこのバージョンの 1 件だけ。
FEED="$BUILD/feed"
mkdir -p "$FEED"
cp "$DMG" "$FEED/"
"$SPM/artifacts/sparkle/Sparkle/bin/generate_appcast" "$FEED" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" --maximum-deltas 0
APPCAST="$FEED/appcast.xml"

mkdir -p "$OUT" && cp "$DMG" "$APPCAST" "$OUT/"
DMG="$OUT/$(basename "$DMG")"
APPCAST="$OUT/appcast.xml"
echo "✅ $DMG"
echo "✅ $APPCAST"

if $PUBLISH; then
  echo "▶ GitHub Release"
  # appcast.xml は「最新リリース」から配信される（ベータ＝prerelease は既存ユーザーに届かない）
  gh release create "v$VERSION" "$DMG" "$APPCAST" --repo "$REPO" --title "$APP_NAME $VERSION" \
    --generate-notes $PRERELEASE
fi
