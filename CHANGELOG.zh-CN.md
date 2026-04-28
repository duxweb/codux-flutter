# 更新日志

项目的重要变更会记录在本文件中。

## [Unreleased]

## [1.0.0] - 2026-04-28

### 新增

- 新增第一版 Codux Mobile Flutter 客户端，通过 relay 服务连接 macOS 端 Codux。
- 支持扫码配对、设备管理、项目切换、终端分屏切换、文件浏览、图片上传和 AI 用量面板。
- 新增基于 Termux TerminalView 的 Android 原生终端 Flutter 插件，支持远程输出、用户输入、滚动历史、文字选择、快捷键和输入法避让。
- 新增 GitHub 更新检查，读取 `duxweb/codux-flutter` 最新 Release。

### 调整

- 移除早期 WebView / xterm 方向，移动端终端改为原生 Android 插件渲染。
- 新增 `CODUX_LOG_LEVEL` 发布日志控制，Flutter 层和原生终端插件共用同一日志等级。

### 修复

- 稳定 Android 输入法避让策略，TUI 程序输入时移动终端显示区域，不再强制触发远端终端 resize。
- 分离用户输入与本地终端响应通道，修复远程终端输入重复和本地 emulator response 回灌问题。
