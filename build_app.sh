#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

app="build/幕台.app"
# Python for the bundled scanner: PYTHON_BIN if set, else Python 3.13 (what
# CI uses), else this Mac's Homebrew python3.
python="${PYTHON_BIN:-}"
if [[ -z "$python" ]]; then
  for candidate in /opt/homebrew/opt/python@3.13/bin/python3.13 /opt/homebrew/bin/python3; do
    if [[ -x "$candidate" ]]; then python="$candidate"; break; fi
  done
fi
[[ -n "$python" && -x "$python" ]] || {
  echo "缺少 Python：brew install python@3.13，或设置 PYTHON_BIN" >&2; exit 1; }
"$python" -c 'import sys; sys.exit(sys.version_info < (3, 11))' || {
  echo "Python 版本过低（需要 3.11 或更新）：$python" >&2; exit 1; }
echo "使用 Python：$("$python" --version) ($python)"
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
  "$python" -m venv build/venv
  build/venv/bin/python -m pip install --disable-pip-version-check 'pyinstaller==6.22.3'
fi
# iPhone / iPad over USB (device info, trust prompt, system log).
ios_library='pymobiledevice3==11.50.3'
build/venv/bin/python -m pip show pymobiledevice3 2>/dev/null | /usr/bin/grep -q '^Version: 11.50.3$' ||
  build/venv/bin/python -m pip install --disable-pip-version-check "$ios_library"
build/venv/bin/pyinstaller --noconfirm --onedir --console --target-arch arm64 \
  --name adb-worker --distpath build/pyinstaller-dist \
  --workpath build/pyinstaller-build --specpath build/pyinstaller-spec \
  --collect-submodules pymobiledevice3 --collect-data pymobiledevice3 worker.py

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
  native/GIFConverter.swift native/WebPConverter.swift \
  native/AppWindows.swift native/AppPicker.swift native/DeviceLogs.swift \
  native/IOSDevices.swift native/IOSMirror.swift
/bin/cp native/Info.plist "$app/Contents/Info.plist"
# Reads app icons on the device for the app picker (run, then deleted there).
/bin/cp android/icons/lanadb-icons.dex "$app/Contents/Resources/lanadb-icons.dex"
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
