---
name: testflight-upload
description: 为 Indo（TravelCompanion）iOS 工程执行最新代码的 Release 打包、签名、IPA 校验、App Store Connect 上传及 TestFlight 内部测试分配。当用户提到 TestFlight、重新打包、上传内测包、iOS 发布包时使用。
---

# Indo TestFlight Upload

## 项目固定配置

- 项目根目录：`/Users/yangzhiyuan/Documents/indo/travel-companion-ios`
- Xcode 项目：`TravelCompanion.xcodeproj`
- Scheme：`TravelCompanion`
- 主应用名称：`TravelCompanion`
- 主应用 Bundle ID：`com.yangzhiyuan.travelcompanion`
- 分享扩展 Bundle ID：`com.yangzhiyuan.travelcompanion.share`
- App Store Connect App ID：`6796555795`（Indo）
- 团队 ID：`9Z29478796`
- Distribution 证书 SHA-1：`A3E24240093D0924BC17227C32EFE18210630E32`
- 内部测试组：`Internal Testers`
- 主应用发布 profile：`Indo Main Release SignIn 20260803`
- 分享扩展发布 profile：`TravelCompanion Share App Store`

`project.yml` 是工程配置源。每次修改该文件后都必须运行 `xcodegen generate`，不要手工修改生成的 `project.pbxproj`。

## 安全要求

- 禁止输出私钥、`.p8`/`.p12` 内容、密码或其他签名密钥材料。
- 使用环境变量 `APP_STORE_CONNECT_KEY_ID`、`APP_STORE_CONNECT_ISSUER_ID`、`APP_STORE_CONNECT_KEY_PATH`（或 `ASC_*` 等价变量）认证；本项目的 `scripts/asc_tool.py` 也支持已有的本机默认凭证。
- 不要用命令行参数覆盖 `PRODUCT_BUNDLE_IDENTIFIER` 或 `PROVISIONING_PROFILE_SPECIFIER`：这会把主应用配置错误地应用到扩展 target，导致 Bundle ID 冲突。

## 发布流程

1. 在项目根目录确认当前配置与签名：

```bash
xcodebuild -list -project TravelCompanion.xcodeproj
security find-identity -v -p codesigning
```

检查 `project.yml` 中 `MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`、两个 Bundle ID、主应用和扩展的 Release profile。

2. 对于每次需要上传的新代码，将 `project.yml` 的 `CURRENT_PROJECT_VERSION` 递增。若 Apple 返回 `previousBundleVersion = N`，将其改为 `N + 1` 后重新完整打包。不要修改测试 target 的 build 号。

3. 生成工程并 Archive。必须让每个 target 使用其在 `project.yml` 中的独立 Bundle ID 和 profile：

```bash
xcodegen generate
xcodebuild archive \
  -project TravelCompanion.xcodeproj \
  -scheme TravelCompanion \
  -configuration Release \
  -archivePath "$PWD/build/TravelCompanion.xcarchive" \
  -destination "generic/platform=iOS" \
  -allowProvisioningUpdates
```

4. 如果 Archive 提示 profile 不含 `com.apple.developer.applesignin`，确认主应用 App ID 已启用 `APPLE_ID_AUTH`，并创建一个唯一命名的主应用 App Store profile。不要复用或创建名为 `TravelCompanion App Store WK` 的 profile，因为历史上该名称同时被用于不同 Bundle ID，Xcode 可能选错。

5. 从 Archive 导出 IPA：

```bash
xcodebuild -exportArchive \
  -archivePath "$PWD/build/TravelCompanion.xcarchive" \
  -exportPath "$PWD/build/export" \
  -exportOptionsPlist "$PWD/build/ExportOptions.plist" \
  -allowProvisioningUpdates
```

`build/ExportOptions.plist` 必须使用 `method=app-store-connect`、手动签名、团队 ID、Distribution 证书 SHA-1，且 profile 映射必须为：

- `com.yangzhiyuan.travelcompanion` → `Indo Main Release SignIn 20260803`
- `com.yangzhiyuan.travelcompanion.share` → `TravelCompanion Share App Store`

6. 发布前校验。解压 IPA 并确认：

- 主应用 Bundle ID 为 `com.yangzhiyuan.travelcompanion`
- 分享扩展 Bundle ID 为 `com.yangzhiyuan.travelcompanion.share`
- `CFBundleShortVersionString` 与本次发布版本一致
- `CFBundleVersion` 为递增后的 build 号
- `ITSAppUsesNonExemptEncryption` 存在且为 `false`
- `build/export/DistributionSummary.plist` 存在

7. 上传：

```bash
xcrun altool --upload-app \
  --type ios \
  --file "$PWD/build/export/TravelCompanion.ipa" \
  --api-key "$APP_STORE_CONNECT_KEY_ID" \
  --apiIssuer "$APP_STORE_CONNECT_ISSUER_ID"
```

当前 Xcode 版本使用 `--api-key`（带连字符）。不要使用过时或不兼容的 `--apiKeyId` / `--apiKey-path` 参数。

8. 等待处理完成并加入内部测试组：

```bash
python3 .codex/skills/testflight-upload/scripts/asc_tool.py poll-and-add \
  --app-id 6796555795 \
  --build-number <BUILD_NUMBER> \
  --group-name "Internal Testers" \
  --create-group
```

只有在 `processingState=VALID` 且 `internalBuildState=READY_FOR_BETA_TESTING` 后才报告完成。

## 常见问题

- **Build number 重复**：增加 `CURRENT_PROJECT_VERSION` 后，从 `xcodegen generate` 开始重新执行。
- **扩展 Bundle ID 与主应用相同**：移除 Archive 命令中覆盖 `PRODUCT_BUNDLE_IDENTIFIER` 的参数，重新 Archive。
- **Sign in with Apple profile 错误**：检查主应用 Developer Bundle ID `R4PCDV59QM` 是否已启用 `APPLE_ID_AUTH`；创建使用唯一名称的主应用 profile，并同时更新 `project.yml` 和 `build/ExportOptions.plist`。
- **profile 名称正确但实际 App ID 不对**：检查 profile 的 `application-identifier` entitlement；必须为 `9Z29478796.com.yangzhiyuan.travelcompanion`，而非 `.share`。
- **`MISSING_EXPORT_COMPLIANCE`**：确认主应用 Info.plist 中含 `ITSAppUsesNonExemptEncryption = false`；递增 build 后重新上传。
