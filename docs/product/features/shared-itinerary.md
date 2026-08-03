# Product Feature: 唯一共享行程

## Description
两人直接进入同一份按日期排列的旅行计划，不展示行程列表。

## Inputs
- 目的地、日期、协作者显示名、卡片操作。

## Outputs
- 唯一行程时间轴、创建/编辑/删除/排序后的同步结果。

## Boundary
### Included
- 单一共享行程、日期与卡片管理、离线待同步。

### Excluded
- 多行程、归档、模板市场、账号与成员角色。

## Acceptance Criteria
- 首次启动直接进入唯一行程；正常网络下另一端 5 秒内可见变更；重启后已同步内容仍在。

## Data And Permissions
- Data touched: SharedTrip、TripDay、ItineraryCard、PendingOperation。
- Owner: 两位协作者共同使用；服务端存储共享部分。
- Permission/auth expectations: 用户确认无访问控制；卡包不属于此功能。

## UX Notes
- Screens/pages: 行程时间轴、日期切换、同步状态。
- Empty/loading/error states: 空日期、新建引导、离线待同步、同步失败重试。
- Human verification: 两台设备分别新增和编辑一项，核验同步和重启持久化。

## Open Questions
- 初次初始化的目的地、日期、币种由谁填写。
