#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MenuBarVisualizer"
CONFIG="${1:-release}"

cd "$ROOT_DIR"

swift build -c "$CONFIG"

APP_DIR="$ROOT_DIR/dist/${APP_NAME}.app"
BIN_PATH="$ROOT_DIR/.build/${CONFIG}/${APP_NAME}"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "Created $APP_DIR"
