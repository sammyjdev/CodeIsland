#!/bin/bash
# Builds LLMOps.app (arm64, ad-hoc signed) from this package. Run from LLMOps/.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="LLMOps"
ARM_DIR=".build/arm64-apple-macosx/release"
APP_BUNDLE=".build/release/$APP_NAME.app"

echo "Building $APP_NAME (arm64)..."
# --build-system native: the default swift-build backend fails with
# "Unknown error parsing property list" when only CommandLineTools is installed.
swift build --build-system native -c release --arch arm64 --product "$APP_NAME"

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$ARM_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

# SwiftPM resource bundle (fonts, sounds). Bundle.module looks next to the
# executable first, then in Contents/Resources of the enclosing .app.
cp -R "$ARM_DIR/${APP_NAME}_${APP_NAME}.bundle" "$APP_BUNDLE/Contents/Resources/"

codesign --force --deep --sign "${SIGN_ID:--}" "$APP_BUNDLE"
echo "Done: $APP_BUNDLE"
