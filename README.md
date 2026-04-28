# Codux Flutter

Codux Mobile 的 Flutter 重构版，复刻当前 React Native 版的远程终端工作台结构，并使用 `xterm.dart` 原生 Flutter 终端渲染。

## 技术栈

- Flutter 3.41+
- `xterm` / `xterm.dart`：终端渲染与输入
- `web_socket_channel`：连接 Codux Go relay server
- `mobile_scanner`：扫码配对
- `shared_preferences`：本地设备与设置存储
- `device_info_plus`：默认读取手机设备名

## 功能范围

- Mac 端二维码配对，支持粘贴二维码 JSON
- 本地保存多台电脑设备
- WebSocket 连接 relay server
- 项目列表、分屏列表、创建/关闭/切换终端
- 远程 PTY 输入输出、resize 同步
- 顶部连接状态、横向项目栏、终端主体、底部快捷工具栏
- 设置页：服务器地址、本机名称
- 终端遮罩过渡层：用于键盘高度变化时遮住重排断层

## 运行

```bash
cd /Volumes/Web/codux-flutter
flutter run
```

## 验证

```bash
flutter analyze
flutter test
flutter build apk --debug
```

Android debug APK 输出：

```text
build/app/outputs/flutter-apk/app-debug.apk
```

## 环境说明

本机已安装：

- Flutter stable 3.41.7
- Android command line tools
- Android SDK 36
- OpenJDK 17，并通过 `flutter config --jdk-dir` 配置给 Flutter

当前 `flutter doctor` 仅剩 iOS Simulator runtime 检查问题，Android toolchain 已通过。
