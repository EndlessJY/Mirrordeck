#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

app="build/幕台.app"
archive="vendor/downloads/scrcpy-macos-aarch64-v5.0.1.tar.gz"
expected_sha="33611e51977a8289e2e124b220f727895181ef2eb9060e0987a4dc2db9cf0d6b"
if [[ ! -f "$archive" ]]; then
  # The official release supplies adb and the device-side server.
  mkdir -p "${archive:h}"
  /usr/bin/curl -fL --retry 3 -o "$archive.part" \
    "https://github.com/Genymobile/scrcpy/releases/download/v5.0.1/${archive:t}"
  /bin/mv "$archive.part" "$archive"
fi
actual_sha="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
[[ "$actual_sha" == "$expected_sha" ]] || { echo "scrcpy 发行包校验失败" >&2; exit 1; }

if [[ ! -d build/custom-scrcpy ]]; then
  /opt/homebrew/bin/meson setup build/custom-scrcpy vendor/scrcpy-source \
    --buildtype=release -Dcompile_server=false -Dportable=true -Dstatic=false
fi
/opt/homebrew/bin/ninja -C build/custom-scrcpy

if [[ ! -x build/venv/bin/pyinstaller ]]; then
  /opt/homebrew/bin/python3 -m venv build/venv
  build/venv/bin/python -m pip install --disable-pip-version-check 'pyinstaller==6.22.3'
fi
build/venv/bin/pyinstaller --noconfirm --onedir --console --target-arch arm64 \
  --name adb-worker --distpath build/pyinstaller-dist \
  --workpath build/pyinstaller-build --specpath build/pyinstaller-spec worker.py

if [[ -d "$app" ]]; then
  /bin/mv "$app" "build/previous-package-$(/bin/date +%Y%m%d%H%M%S).app"
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# libwebp (animated WebP export) is linked statically from Homebrew's webp.
webp=/opt/homebrew/opt/webp
[[ -f "$webp/lib/libwebpmux.a" ]] || { echo "缺少 libwebp 静态库：brew install webp" >&2; exit 1; }
/usr/bin/swiftc -O -parse-as-library -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -framework SwiftUI -framework AppKit -framework Network \
  -import-objc-header native/WebPBridge.h -I "$webp/include" \
  -Xlinker "$webp/lib/libwebpmux.a" -Xlinker "$webp/lib/libwebp.a" \
  -Xlinker "$webp/lib/libsharpyuv.a" \
  -o "$app/Contents/MacOS/LANADBManager" \
  native/ADBManagerApp.swift native/Theme.swift native/MirrorStore.swift native/DeviceActions.swift \
  native/GIFConverter.swift native/WebPConverter.swift
/bin/cp native/Info.plist "$app/Contents/Info.plist"
# CI passes its run number so every build has a distinct build version.
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$app/Contents/Info.plist"
fi
/usr/bin/ditto build/pyinstaller-dist/adb-worker "$app/Contents/Resources/Worker"
mkdir -p "$app/Contents/Resources/Tools"
/usr/bin/tar -xf "$archive" -C "$app/Contents/Resources/Tools" --strip-components=1
/bin/rm "$app/Contents/Resources/Tools/scrcpy"
mirror="$app/Contents/Helpers/LANADBMirror.app"
/bin/mkdir -p "$mirror/Contents/MacOS"
/bin/cp native/MirrorInfo.plist "$mirror/Contents/Info.plist"
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$mirror/Contents/Info.plist"
fi
/bin/cp build/custom-scrcpy/app/scrcpy "$mirror/Contents/MacOS/scrcpy"
/opt/homebrew/bin/dylibbundler -od -b -x "$mirror/Contents/MacOS/scrcpy" \
  -d "$mirror/Contents/MacOS/lib" -p @executable_path/lib \
  > build/dylibbundler.log 2>&1
count="$(/usr/bin/otool -l "$mirror/Contents/MacOS/scrcpy" | \
  /usr/bin/awk '$1 == "path" && $2 == "@executable_path/lib/" { n++ } END { print n+0 }')"
for ((i = 1; i < count; i++)); do
  /usr/bin/install_name_tool -delete_rpath @executable_path/lib/ "$mirror/Contents/MacOS/scrcpy"
done
/bin/echo -n 'APPL????' > "$app/Contents/PkgInfo"
/usr/bin/swift native/make_icon.swift "$app/Contents/Resources/AppIcon-1024.png"
iconset="build/AppIcon.iconset"
mkdir -p "$iconset"
for points in 16 32 128 256 512; do
  /usr/bin/sips -z "$points" "$points" "$app/Contents/Resources/AppIcon-1024.png" \
    --out "$iconset/icon_${points}x${points}.png" >/dev/null
  pixels=$((points * 2))
  /usr/bin/sips -z "$pixels" "$pixels" "$app/Contents/Resources/AppIcon-1024.png" \
    --out "$iconset/icon_${points}x${points}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
mkdir -p "$mirror/Contents/Resources"
/bin/cp "$app/Contents/Resources/AppIcon.icns" "$mirror/Contents/Resources/AppIcon.icns"
# The bundled Homebrew libraries decide the oldest macOS the app runs on
# (they are built for the macOS of the build machine). Libraries load on any
# release of their major version, so declare that major version.
major="$(/usr/bin/find "$app" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0 | \
  /usr/bin/xargs -0 /usr/bin/otool -l 2>/dev/null | \
  /usr/bin/awk '$1 == "minos" { split($2, v, "."); print v[1] }' | /usr/bin/sort -n | /usr/bin/tail -1)"
minimum="${major:-14}.0"
for plist in "$app/Contents/Info.plist" "$mirror/Contents/Info.plist"; do
  /usr/libexec/PlistBuddy -c "Delete :LSMinimumSystemVersion" "$plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $minimum" "$plist"
done
echo "最低支持系统：macOS $minimum"
/usr/bin/codesign --force --deep --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"
echo "已构建 $PWD/$app"
