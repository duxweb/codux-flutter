# Codux Mobile 发布仓库

当前仓库保留为 Codux Mobile 的公开发布和签名构建壳。

移动端源码现在维护在 Codux monorepo：

- 源码：`https://github.com/duxweb/codux/tree/main/apps/mobile`
- 移动端公开发布：`https://github.com/duxweb/codux-flutter/releases`

## 发布模型

当前仓库的 workflows 不再构建本仓库内的旧源码。它们会 checkout `duxweb/codux` 的同名 tag，并从 monorepo 的 `apps/mobile` 构建移动端。

发布移动端版本：

1. 在 `duxweb/codux` 提交移动端源码变更。
2. 给 monorepo 打 tag 并推送：

```bash
cd /Volumes/Web/codux-gpui
git tag v1.8.0
git push origin main
git push origin v1.8.0
```

3. 在当前发布仓推送同名 tag：

```bash
cd /Volumes/Web/codux-flutter
git tag v1.8.0
git push origin v1.8.0
```

当前仓库的 tag 只作为发布触发器。Android 和 iOS workflows 会构建 `duxweb/codux@v1.8.0`。

## Workflows

- `.github/workflows/release-build.yml`：从 `duxweb/codux/apps/mobile` 构建签名 Android APK，并发布到当前仓库的 GitHub Release。
- `.github/workflows/ios-testflight.yml`：从 `duxweb/codux/apps/mobile` 构建 iOS IPA，并上传到 TestFlight。
- `.github/workflows/test-build.yml`：从 `duxweb/codux/apps/mobile` 执行手动 Android 测试构建。通过 `source_ref` 指定 monorepo 的 branch、tag 或 commit SHA。

## Secrets

Android 正式签名继续使用当前仓库已有 secrets：

- `CODUX_ANDROID_KEYSTORE_BASE64`
- `CODUX_ANDROID_KEYSTORE_PASSWORD`
- `CODUX_ANDROID_KEY_ALIAS`
- `CODUX_ANDROID_KEY_PASSWORD`

iOS / TestFlight 发布继续使用当前仓库已有 secrets：

- `IOS_DISTRIBUTION_CERT_BASE64`
- `IOS_DISTRIBUTION_CERT_PASSWORD`
- `IOS_PROVISIONING_PROFILE_BASE64`
- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_API_ISSUER_ID`
- `APP_STORE_CONNECT_API_KEY_P8_BASE64`

## 更新日志

`CHANGELOG.md` 和 `CHANGELOG.zh-CN.md` 保留在当前仓库，用于移动端发布页。workflow 会从 `duxweb/codux/apps/mobile` 下的同名文件提取发布说明。

## 开源协议

Codux Mobile 使用 GNU General Public License v3.0。详情见 `LICENSE`。
