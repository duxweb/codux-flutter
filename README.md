# Codux Mobile Release Repository

This repository is kept as the public release and signing shell for Codux Mobile.

The mobile source code now lives in the Codux monorepo:

- Source: `https://github.com/duxweb/codux/tree/main/apps/mobile`
- Public mobile releases: `https://github.com/duxweb/codux-flutter/releases`

## Release Model

The workflows in this repository do not build the checked-in source from this repository. They checkout `duxweb/codux` and build `apps/mobile` from the monorepo.

For a mobile release:

1. Commit the mobile source changes in `duxweb/codux`.
2. Tag and push the monorepo:

```bash
cd <codux-repo>
git tag v1.8.0
git push origin main
git push origin v1.8.0
```

3. Push the same tag in this release repository:

```bash
cd <codux-flutter-release-repo>
git tag v1.8.0
git push origin v1.8.0
```

The tag in this repository is only the release trigger. A tag push builds the matching `duxweb/codux` tag. For a mobile-only rebuild or hotfix, use `workflow_dispatch` and set `source_ref` to the monorepo branch, tag, or commit SHA; do not move the monorepo release tag just to rerun mobile packaging.

## Workflows

- `.github/workflows/release-build.yml`: builds the signed Android APK from `duxweb/codux/apps/mobile` and publishes it to this repository's GitHub Release. Manual runs can set `source_ref`.
- `.github/workflows/ios-testflight.yml`: builds the iOS IPA from `duxweb/codux/apps/mobile` and uploads it to TestFlight. Manual runs can set `source_ref`.
- `.github/workflows/test-build.yml`: manual Android test builds from `duxweb/codux/apps/mobile`. Use `source_ref` to choose the monorepo branch, tag, or commit SHA.

## Secrets

Android release signing uses the existing repository secrets:

- `CODUX_ANDROID_KEYSTORE_BASE64`
- `CODUX_ANDROID_KEYSTORE_PASSWORD`
- `CODUX_ANDROID_KEY_ALIAS`
- `CODUX_ANDROID_KEY_PASSWORD`

iOS / TestFlight release uses the existing repository secrets:

- `IOS_DISTRIBUTION_CERT_BASE64`
- `IOS_DISTRIBUTION_CERT_PASSWORD`
- `IOS_PROVISIONING_PROFILE_BASE64`
- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_API_ISSUER_ID`
- `APP_STORE_CONNECT_API_KEY_P8_BASE64`

## Changelog

`CHANGELOG.md` and `CHANGELOG.zh-CN.md` are kept here for the mobile release page. The workflow extracts release notes from the matching files under `duxweb/codux/apps/mobile`.

## License

Codux Mobile is licensed under the GNU General Public License v3.0. See `LICENSE` for details.
