#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/MacWin Manager.app"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"
MACOS="$CONTENTS/MacOS"
PLIST="$CONTENTS/Info.plist"
BUILD_CONFIGURATION="${MACWIN_BUILD_CONFIGURATION:-release}"
case "$BUILD_CONFIGURATION" in
    debug|release) ;;
    *)
        printf 'Unsupported MACWIN_BUILD_CONFIGURATION: %s (use debug or release)\n' "$BUILD_CONFIGURATION" >&2
        exit 2
        ;;
esac
BUILD_DIR="$ROOT/.build/arm64-apple-macosx/$BUILD_CONFIGURATION"
EXECUTABLE="$BUILD_DIR/MacWinManagerApp"
RESOURCE_BUNDLE="$BUILD_DIR/MacWinManager_MacWinManagerApp.bundle"
ICONS="$ROOT/Sources/MacWinManagerApp/Resources/Icons"
ASSET_CATALOG="$ROOT/Sources/MacWinManagerApp/Resources/AppAssets.xcassets"
ASSET_INFO="$ROOT/.build/macwin-app-icon-info.plist"
MODULE_CACHE="$ROOT/.build/macwin-module-cache"
NATIVE_UI_PROBE_BUILD="$ROOT/.build/native-ui-probe"
mkdir -p "$MODULE_CACHE"

(
    cd "$ROOT"
    swift -module-cache-path "$MODULE_CACHE" Tools/generate-icons.swift
)
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
swift build --disable-sandbox --package-path "$ROOT" --configuration "$BUILD_CONFIGURATION" --jobs 1
"$ROOT/Tools/build-native-ui-probe.sh" "$NATIVE_UI_PROBE_BUILD"

mkdir -p "$MACOS" "$RESOURCES"
cp -f "$EXECUTABLE" "$MACOS/MacWinManagerApp"
rm -rf "$RESOURCES/MacWinManager_MacWinManagerApp.bundle"
cp -R "$RESOURCE_BUNDLE" "$RESOURCES/"
rm -rf "$RESOURCES/NativeUIProbe"
mkdir -p "$RESOURCES/NativeUIProbe"
cp -f "$NATIVE_UI_PROBE_BUILD/native-ui-probe-x86_64.exe" "$RESOURCES/NativeUIProbe/"
cp -f "$NATIVE_UI_PROBE_BUILD/native-ui-probe-i686.exe" "$RESOURCES/NativeUIProbe/"
cp -f "$ICONS/MacWinAppIcon.icns" "$RESOURCES/MacWinAppIcon.icns"
cp -f "$ICONS/MacWinExeDocument.icns" "$RESOURCES/MacWinExeDocument.icns"
rm -f "$RESOURCES/AppIcon.icns" "$RESOURCES/Assets.car"
xcrun actool "$ASSET_CATALOG" \
    --compile "$RESOURCES" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$ASSET_INFO" \
    --target-device mac \
    --bundle-identifier dev.local.macwin.manager \
    --product-type com.apple.product-type.application \
    --output-format human-readable-text

/usr/bin/python3 - "$PLIST" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
plist = {
    "CFBundleDisplayName": "MacWin Manager",
    "CFBundleExecutable": "MacWinManagerApp",
    "CFBundleIconFile": "MacWinAppIcon.icns",
    "CFBundleIconName": "AppIcon",
    "CFBundleIdentifier": "dev.local.macwin.manager",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "MacWin Manager",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": "14",
    "LSApplicationCategoryType": "public.app-category.utilities",
    "LSMinimumSystemVersion": "14.0",
    "NSHighResolutionCapable": True,
    "NSAppleEventsUsageDescription": "MacWin Manager uses System Events to focus Wine application windows and perform optional window repair actions you enable.",
    "CFBundleDocumentTypes": [
        {
            "CFBundleTypeExtensions": ["exe"],
            "CFBundleTypeIconFile": "MacWinExeDocument.icns",
            "CFBundleTypeName": "Windows Executable",
            "CFBundleTypeRole": "Shell",
            "LSHandlerRank": "Alternate",
            "LSItemContentTypes": [
                "com.microsoft.windows-executable",
                "dev.local.macwin.windows-executable"
            ]
        }
    ],
    "UTImportedTypeDeclarations": [
        {
            "UTTypeConformsTo": ["public.executable", "public.data"],
            "UTTypeDescription": "Windows Executable",
            "UTTypeIconFile": "MacWinExeDocument.icns",
            "UTTypeIdentifier": "com.microsoft.windows-executable",
            "UTTypeTagSpecification": {
                "public.filename-extension": ["exe"],
                "public.mime-type": ["application/vnd.microsoft.portable-executable"]
            }
        }
    ],
    "UTExportedTypeDeclarations": [
        {
            "UTTypeConformsTo": ["public.executable", "public.data"],
            "UTTypeDescription": "MacWin Windows Executable",
            "UTTypeIconFile": "MacWinExeDocument.icns",
            "UTTypeIdentifier": "dev.local.macwin.windows-executable",
            "UTTypeTagSpecification": {
                "public.filename-extension": ["exe"]
            }
        }
    ]
}
path.write_bytes(plistlib.dumps(plist, sort_keys=False))
PY

printf 'APPL????' > "$CONTENTS/PkgInfo"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
touch "$APP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
fi
echo "$APP"
