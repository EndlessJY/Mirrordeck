# 幕台 Mirrordeck

macOS 原生的多设备投屏与管理工具，支持 Android 手机、平板、模拟器，以及 USB 连接的 iPhone / iPad。ADB、scrcpy 等组件都打包在应用内，无需另外安装。

## 功能

- **自动发现设备**：USB、无线调试、连接过的地址和本机模拟器；USB 连接的 Android 设备自动开启无线 ADB，拔线后继续可用。默认不扫描整个网段，适合企业内网。
- **投屏**：画面、声音、键盘输入（中文走 Mac 输入法），标题栏提供返回、首页、通知栏、音量、锁屏、熄屏等按钮。
- **截图、录屏、动图**：一键保存并复制到剪贴板，可直接粘贴到飞书等聊天软件（视频以可播放的形式发送）；动图可选 WebP 或 GIF。
- **单应用窗口**（Android 10+）：把手机上的某个应用单独开成 Mac 窗口，不影响手机屏幕；支持拼音和首字母搜索。
- **设备日志**：实时日志，按级别、关键字、应用筛选，崩溃自动标红。
- **设备信息**：型号、系统、硬件、电池、网络等，点按即可复制。
- **iPhone / iPad（USB）**：设备信息、投屏（只看不操控）、截图录屏、系统日志。

## 下载

在 [Releases](https://github.com/EndlessJY/Mirrordeck/releases) 下载最新版本（Apple 芯片 Mac）。每次推送到 `main` 都会自动构建并发布一个新版本，版本号形如 `v4.0.13`。

应用未经 Apple 公证，首次打开请在“系统设置 › 隐私与安全性”中选择“仍要打开”。

## 使用须知

- Android 需在设备上打开 USB 调试或无线调试，首次授权和配对码只能在设备上确认。
- iPhone 需解锁并点“信任此电脑”；首次投屏需允许“相机”和“麦克风”权限（只用于 iPhone 的画面和声音）。
- 键盘输入和粘贴会经过设备剪贴板，请勿输入敏感信息。
- 截图和录屏默认保存到桌面，可在设置（`⌘,`）中修改保存位置、画质和格式。
- 关闭主窗口不会中断正在进行的投屏、应用窗口或录制；它们全部结束后应用自动退出。

## 开发与构建

```sh
./build_app.sh                                    # 构建到 build/幕台.app
/usr/bin/python3 -m unittest discover -s tests    # 单元测试
```

依赖：Swift、Python 3.11+、Meson、Ninja、dylibbundler，以及 Homebrew 的 `sdl3 ffmpeg libusb webp`。构建脚本会自动准备 PyInstaller、pymobiledevice3 和官方 scrcpy 发行包。CI 流程见 `.github/workflows/build.yml`。

修改过的 scrcpy 源码在 `vendor/scrcpy-source`，改动处以 `LANADB` 注释标出；界面规范见 [DESIGN.md](DESIGN.md)。
