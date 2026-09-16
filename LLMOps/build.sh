#!/bin/bash
# Builds LLMOps.app (arm64, ad-hoc signed) from this package. Run from LLMOps/.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="LLMOps"
WIDGETS_NAME="LLMOpsWidgets"
ARM_DIR=".build/arm64-apple-macosx/release"
APP_BUNDLE=".build/release/$APP_NAME.app"
APPEX_BUNDLE="$APP_BUNDLE/Contents/PlugIns/$WIDGETS_NAME.appex"

echo "Building $APP_NAME (arm64)..."
# --build-system native: the default swift-build backend fails with
# "Unknown error parsing property list" when only CommandLineTools is installed.
swift build --build-system native -c release --arch arm64 --product "$APP_NAME"

echo "Building $WIDGETS_NAME (arm64)..."
swift build --build-system native -c release --arch arm64 --product "$WIDGETS_NAME"

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$ARM_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# SwiftPM resource bundle (fonts, sounds). Bundle.module looks next to the
# executable first, then in Contents/Resources of the enclosing .app.
cp -R "$ARM_DIR/${APP_NAME}_${APP_NAME}.bundle" "$APP_BUNDLE/Contents/Resources/"

# WidgetKit extension
mkdir -p "$APPEX_BUNDLE/Contents/MacOS"
cp "$ARM_DIR/$WIDGETS_NAME" "$APPEX_BUNDLE/Contents/MacOS/$WIDGETS_NAME"
cp WidgetsInfo.plist "$APPEX_BUNDLE/Contents/Info.plist"

BUILD_VERSION="$(date +%s)"
plutil -replace CFBundleVersion -string "$BUILD_VERSION" "$APPEX_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_VERSION" "$APP_BUNDLE/Contents/Info.plist"

# Appex first, with its entitlements. No --deep on the app: --deep would re-sign
# the appex and drop the sandbox entitlement it needs to reach its container.
codesign --force --sign "${SIGN_ID:--}" --entitlements Widgets.entitlements "$APPEX_BUNDLE"
codesign --force --sign "${SIGN_ID:--}" "$APP_BUNDLE"
echo "Done: $APP_BUNDLE"

