#!/bin/zsh
# 自分の Mac で常用するためのインストール。
# Apple Development 証明書で署名するので、再ビルドしてもアクセシビリティ等の許可が外れにくい。
#
#   ./scripts/install-local.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Denko"
# Documents 内はファイルに拡張属性が付いて署名できないことがあるので、一時フォルダでビルドする
BUILD_DIR="${TMPDIR:-/tmp}/$APP_NAME-build"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 'Apple Development' | sed -E 's/.*"(.*)"/\1/')}"

if [[ -z "$IDENTITY" ]]; then
  echo "Apple Development 証明書が見つかりません。Xcode → 設定 → アカウント で作成してください。" >&2
  exit 1
fi

xcodegen generate >/dev/null
# パッケージ（Sparkle）を先に取得しておく（ビルド中の展開が間に合わず失敗することがあるため）
xcodebuild -resolvePackageDependencies -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -derivedDataPath "$BUILD_DIR" >/dev/null 2>&1 || true
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath "$BUILD_DIR" CODE_SIGN_IDENTITY="-" build > "$BUILD_DIR.log" 2>&1 || {
  grep -E "error:" "$BUILD_DIR.log" | head -20; echo "ビルドに失敗しました（インストールしていません）" >&2; exit 1; }
grep -E "BUILD" "$BUILD_DIR.log" || true

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
xattr -cr "$APP"
codesign --force --deep --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
# 本体だけ entitlements（位置情報）付きで署名し直す
codesign --force --options runtime --timestamp=none --entitlements Denko/App/Denko.entitlements --sign "$IDENTITY" "$APP"

# 動いている古い版を終了して入れ替える
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP" /Applications/
open "/Applications/$APP_NAME.app"
echo "インストールしました: /Applications/$APP_NAME.app（署名: $IDENTITY）"
