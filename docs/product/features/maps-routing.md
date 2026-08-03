# Product Feature: 地图、距离与路线

## Description
让用户看到相邻景点的距离与预计通行时间，并一键在地图中查看路线。

## Inputs
- 两个已定位地点、交通方式。

## Outputs
- 距离、时长、数据更新时间和外部导航入口。

## Boundary
### Included
- 地点搜索/坐标、路线估算、高德/网页地图跳转。

### Excluded
- App 内完整导航、离线地图、实时交通承诺。

## Acceptance Criteria
- 两个有坐标地点返回结果或明确错误；点击可打开起终点路线；无 App 时回退网页。

## Data And Permissions
- Data touched: Place、RouteEstimate、路线缓存。
- Owner: 地点可共享；缓存本机保存。
- Permission/auth expectations: Flask 保护 Web Service Key，不发送卡包。

## UX Notes
- Screens/pages: 地点编辑、路线 Sheet、地图跳转。
- Empty/loading/error states: 未定位、加载中、网络/配额/地点错误与重试。
- Human verification: 选定两个真实地点，对比距离/时长并核验外部路线。

## Open Questions
- 是否支持步行、驾车、公共交通三种方式。
