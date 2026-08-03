# Feature Implementation: 本机私密卡包

## Goal
在当前设备离线保存、遮挡和复制旅行常用号码；卡包永不参与服务器同步或共享。

## Files
- Create: iOS `Features/Wallet/{WalletView,WalletEditorView}.swift`、`Data/WalletModels.swift`、`Core/{KeychainStore,WalletCrypto}.swift`、`Tests/WalletTests.swift`。
- Modify: `ContentView.swift`、`TravelCompanionApp.swift`、Xcode 工程的本地文件保护配置。

## Tasks

### Task 1: 加密本地存储
- Files: `WalletModels.swift`、`KeychainStore.swift`、`WalletCrypto.swift`。
- Implementation: SwiftData 只保存标签、时间和 AES-GCM 密文；首次创建时生成随机对称密钥，保存在 ThisDeviceOnly Keychain，数据文件设为 `NSFileProtectionComplete`。号码/备注解密只在内存显示或复制；MVP 不使用后端、CloudKit 或共享容器。
- Verification: 单元测试加解密、遮挡和重启读取；在 APIClient 测试中断言钱包模型无法编码为网络 DTO。

### Task 2: 钱包 UI 与复制
- Files: `WalletView.swift`、`WalletEditorView.swift`。
- Implementation: 支持新增、编辑、删除确认、默认遮挡/短暂显示和 `UIPasteboard` 复制反馈；首次复制提示剪贴板可能被其他 App 读取。不默认定时清空剪贴板，避免覆盖用户后续复制内容。
- Verification: 模拟器创建、改删、重启和复制；检查网络代理日志中不含标签、号码或备注。

## API/Data Changes
- 无服务端路由、表、请求、响应或日志字段；`LocalWalletItem` 仅本机 SwiftData 实体。
- Face ID 不属于 MVP；如果后续启用，只作为本机显示前的额外门槛。

## Edge Cases
- Keychain 项丢失/设备迁移后密文不可恢复：显示安全清理说明，不能尝试上传或恢复到服务端。
- 号码为空、标签为空或复制失败必须给出本地校验/错误反馈。

## Human Verification
- 在设备 A 建立护照号，确认设备 B 和所有 API 请求均看不到数据；卸载重装后确认不会错误声称可恢复。

## Done Criteria
- 卡包可离线安全管理与复制，重启后可读；没有任何云同步、API 调用或共享入口。
