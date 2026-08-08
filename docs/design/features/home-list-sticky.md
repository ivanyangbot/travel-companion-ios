# Feature Implementation: 首页行程列表与分层吸顶

## Goal
将首页列表模式改造成参考长图的紧凑分日浏览体验，并以单一共享时间轴组件和 SwiftUI 原生 pinned section headers 实现稳定的三层滚动层级。

## Files
- Create: N/A
- Modify: `Sources/TravelCompanion/Features/Today/TodayView.swift`
- Modify: `Sources/TravelCompanion/Features/Itinerary/ItineraryView.swift`
- Modify: `Tests/TravelCompanionTests/TravelCardsTests.swift`

## Tasks

### Task 1: 共享日期时间轴
- Files: `TodayView.swift`、`ItineraryView.swift`
- Implementation: 将 `TodayDateTimeline` 从文件私有提升为模块内共享组件；列表直接调用，传入相同的日期格式、今日索引和选择回调。
- Verification: 编译通过；地图与列表的时间轴均由 `TodayDateTimeline` 渲染。

### Task 2: 分层吸顶与双向日期联动
- Files: `ItineraryView.swift`
- Implementation: 顶部固定行程标题和时间轴；正文使用 `LazyVStack(pinnedViews: [.sectionHeaders])`；日期 Section header 负责 push-off 替换。时间轴点击通过 `ScrollViewReader` 定位，滚动几何偏好更新当前日期。
- Verification: 自动化测试日期格式/摘要；模拟器上下滚动和点击时间轴检查吸顶与选择。

### Task 3: 长图式紧凑列表
- Files: `ItineraryView.swift`
- Implementation: 每日卡片使用紧凑横向图片/信息布局，相邻卡片继续复用路线估算；详情、编辑、添加、删除、切换地图等入口保持可达。
- Verification: 小屏模拟器截图与交互检查，确认文字不遮挡、空日期可操作。

## API/Data Changes
- 无 API、数据库或持久化模型变化。
- 当日摘要从当天排序后的前两张卡片名称派生，仅用于显示。

## Edge Cases
- 行程无日期、日期无卡片、日期字符串解析失败。
- 当前日期不在旅行范围时，今日基准取最近日期。
- 时间轴点击触发的程序化滚动不能被中途几何回调改回旧日期。
- 大号文字时日期摘要应压缩/截断，不覆盖日期与星期。

## Human Verification
- 在 iPhone 模拟器上滚过至少三个日期，确认下一日期标题把当前标题推出而非叠加。
- 点击首日、末日和“今日”时间轴按钮，确认定位与选中态一致。
- 切到地图模式，确认时间轴样式与交互未回归。

## Done Criteria
- 需求验收项全部有代码证据；相关测试与 Debug 构建通过；完成模拟器视觉验证。
