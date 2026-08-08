# Feature Implementation: 首页行程列表与分层吸顶

## Goal
将首页列表模式改造成参考长图的紧凑分日浏览体验，并以单一共享时间轴组件和 SwiftUI 原生 pinned section headers 实现稳定的三层滚动层级。

## Files
- Create: N/A
- Modify: `Sources/TravelCompanion/Features/Today/TodayView.swift`
- Modify: `Sources/TravelCompanion/Features/Itinerary/ItineraryView.swift`
- Modify: `Tests/TravelCompanionTests/TravelCardsTests.swift`
- Create: `Assets.xcassets/icon-delete-outline.imageset/*`

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

### Task 4: 卡片长按拖动排序与路线重算
- Files: `ItineraryView.swift`、`SyncEngine.swift`、`TravelCardsTests.swift`
- Implementation: 使用长按后连续拖动的自定义手势；拖动卡片保持 100% 不透明并轻微放大，数据顺序不变，仅将源位置与目标位置之间的卡片平移一个卡位形成占位提示。同日插入点不绘制卡片级橙色描边；跨日时只在目标日期的完整行程容器上绘制橙色边框，目标日期为空时仍显示明确的落位提示。松手后，同日由 `SyncEngine.reorderCards` 保存 position；跨日由 `SyncEngine.moveCard` 更新目标 `dayId`、按日期差平移 startAt/endAt，并重新编号源日和目标日的 position。根层保留独立 settling 副本及松手中心点，真实卡片在新布局中保持隐藏；布局坐标稳定后副本从松手中心动画到目标 frame，完成后再切回真实卡片。路线组件以新的有向相邻卡片 leg key 作为 identity，新相邻关系只在落位后读取对应缓存或发起计算。
- Verification: 单测验证同日 position、跨日 `dayId`/时间/源目标 position PATCH 和有向路线 key；模拟器长按拖动后检查顺序、相邻路线及重启持久化。

### Task 5: 根层拖动副本、手势仲裁与边缘自动滚动
- Files: `ItineraryView.swift`、`TravelCardsTests.swift`
- Implementation: 原卡片进入拖动后隐藏，在列表根层按根坐标绘制等尺寸副本并使用最高 zIndex。排序使用与 ScrollView 同时识别且不取消底层触摸的 `UILongPressGestureRecognizer`：0.3 秒内移动超过 12pt 会在识别前失败，由页面滚动完整接管；长按成功后按窗口坐标持续输出位移，移动超过 3pt 才进入拖卡状态。独立的左滑操作使用带 `UIGestureRecognizerDelegate` 方向门控的 `UIPanGestureRecognizer`：仅横向明显占优且方向向左时开始识别，纵向或方向不明确时在 recognizer begin 阶段直接失败并交还 ScrollView；长按和左滑会互相禁用，确保排序和操作抽屉互斥。通过 ScrollPosition 与 onScrollGeometryChange 跟踪精确偏移，手指进入上下 72...110pt 边缘区后以 90...720pt/s 连续滚动，速度按边缘接近度的 1.55 次曲线变化。
- Verification: 单测覆盖 3pt 激活阈值、中心零速度、上下方向、越靠边越快和最大速度；Debug 模拟器构建验证根层布局与滚动 API。

### Task 6: 列表卡片左滑编辑/删除
- Files: `ItineraryView.swift`、`Assets.xcassets/icon-delete-outline.imageset/*`、`TravelCardsTests.swift`
- Implementation: 在紧凑卡片后方放置两个最终宽度各 72pt 的操作按钮，编辑使用 `icon-edit-outline`，删除使用本地 `icon-delete-outline` SVG；编辑按钮的水平位移始终等于当前展开宽度的一半，删除按钮同步淡入，因此两者从滑动开始按 1:1 同时展开，而不是依次出现。原生横向 pan 的速度方向达到 1.25 倍纵向速度且向左时才接管卡片偏移，偏移限制在 0...144pt，并按预测终点与 42% 阈值吸附；抽屉已展开时允许向右关闭。全局只保留一个展开卡片；点击卡片、开始长按排序或执行操作都会收起。编辑复用 `CardEditorTarget.edit`，删除复用现有确认框与 `SyncEngine.deleteCard`。
- Verification: 单测覆盖横纵方向判定、左右边界和展开阈值；资产编译、Debug 构建与模拟器展开态截图通过。

## API/Data Changes
- 无 API、数据库或持久化模型变化。
- 当日摘要从当天排序后的前两张卡片名称派生，仅用于显示。

## Edge Cases
- 行程无日期、日期无卡片、日期字符串解析失败。
- 当前日期不在旅行范围时，今日基准取最近日期。
- 时间轴点击触发的程序化滚动不能被中途几何回调改回旧日期。
- 大号文字时日期摘要应压缩/截断，不覆盖日期与星期。
- 左滑、普通纵向滚动与长按排序必须并行仲裁；操作层展开时再次点击卡片只收起，不误进详情。
- 松手后新 frame 可能仍处于列表重排动画中；settling 副本应等待坐标稳定再归位，并在布局不可用时超时恢复真实卡片，不能永久隐藏。

## Human Verification
- 在 iPhone 模拟器上滚过至少三个日期，确认下一日期标题把当前标题推出而非叠加。
- 点击首日、末日和“今日”时间轴按钮，确认定位与选中态一致。
- 切到地图模式，确认时间轴样式与交互未回归。

## Done Criteria
- 需求验收项全部有代码证据；相关测试与 Debug 构建通过；完成模拟器视觉验证。
