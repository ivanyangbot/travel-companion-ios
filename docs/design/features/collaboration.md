# Feature Implementation: 双人协作与同步反馈

## Goal
让两台设备对同一个公开单例行程和支出进行前台短轮询同步，并在离线重试和最后写入覆盖时给出诚实反馈。

## Files
- Create: iOS `Core/{SyncEngine,PendingOperationStore,SyncStatus}.swift`、`Features/Settings/SyncStatusView.swift`、`Tests/SyncEngineTests.swift`；后端 `app/services/sync.py`、`tests/test_sync.py`。
- Modify: iOS `Core/APIClient.swift`、`Data/SharedTripRepository.swift`、根导航工具栏；后端 `app/{models,errors}.py`、全部共享写路由。

## Tasks

### Task 1: 版本、幂等与离线队列
- Files: `SyncEngine.swift`、`PendingOperationStore.swift`、`APIClient.swift`、`app/services/sync.py`。
- Implementation: 每个共享写请求传 UUID `Idempotency-Key` 和读取快照时的 `X-Expected-Trip-Version`；后端对相同 key 返回首次响应，版本过期仍按最后写入优先执行并回传 `meta.conflict=true,tripVersion`。SwiftData 按创建顺序保存 method/path/body/key/baseVersion，前台启动、网络恢复和每次编辑后重放；成功后拉取完整 `/v1/trip` 快照。
- Verification: iOS 单元测试队列顺序/重试；pytest 覆盖重复 key、旧版本、删除后重放和事务回滚。

### Task 2: 短轮询和可见状态
- Files: `SyncEngine.swift`、`SyncStatusView.swift`、根工具栏。
- Implementation: App 在前台时每 5 秒 `GET /v1/trip?afterVersion=n`，204 不改变 UI，200 原子合并服务器快照；退到后台停止定时器。顶部显示“已同步/同步中/待同步/离线/可能覆盖”，提供手动重试；显示名仅本机偏好，不能表示身份或权限。
- Verification: 两个模拟器运行同一 API，任一编辑在 5 秒内出现；断网修改、恢复后重放；并发编辑同字段后看到覆盖提示。

## API/Data Changes
- 单例 `SharedTrip(id=1)` 的 `version` 为所有共享资源的全局单调版本；`GET /v1/trip` 是唯一同步快照入口。
- 无认证/授权，接口公开；`Idempotency-Key` 是可靠重试键而非访问令牌，`X-Expected-Trip-Version` 是冲突提示依据而非并发锁。

## Edge Cases
- 网络不可达时保留队列并指数退避，用户可手动重试；不在后台持续轮询。
- 收到无法合并的快照时使用服务器快照并保留“可能覆盖”提示；钱包绝不进入 PendingOperation。

## Human Verification
- 两设备同时编辑同一卡片，验证最后保存者内容存在且先保存者看到提示；连续离线创建卡片/支出后恢复，验证无重复。

## Done Criteria
- 正常前台网络 5 秒内可见共享更新；重复请求不重复写入，离线可恢复，且公开协作风险在 UI/文档中明确说明。
