# Product Feature: 双人协作与同步反馈

## Description
两台设备对同一行程和支出进行近实时协作，并看到基本同步状态和冲突结果。

## Inputs
- 设备显示名、共享数据修改、本地待同步操作。

## Outputs
- 同步状态、远端更新、最后写入优先的冲突提示。

## Boundary
### Included
- 前台短轮询、操作立即刷新、离线队列和恢复重试。

### Excluded
- WebSocket、CRDT、历史版本、第三人及权限层级。

## Acceptance Criteria
- 正常网络下变更 5 秒内可见；离线改动恢复网络后重试；同字段并发时显示可能被覆盖的提示。

## Data And Permissions
- Data touched: 服务端版本号、修改时间、DeviceProfile、PendingOperation。
- Owner: 双方共享；本机队列归设备。
- Permission/auth expectations: 按用户选择完全公开；不得把访问公开误称为安全协作。

## UX Notes
- Screens/pages: 顶部同步状态、冲突提示、基础设备设置。
- Empty/loading/error states: 未连接、同步中、待同步、冲突、重试。
- Human verification: 两台设备同时编辑同一卡片，核验最近版本和提示。

## Open Questions
- 是否在首版显示“最后由谁修改”。
