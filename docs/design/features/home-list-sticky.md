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
- Implementation: 原卡片进入拖动后隐藏，在列表根层按根坐标绘制等尺寸副本并使用最高 zIndex。排序 `UILongPressGestureRecognizer` 挂在列表根层而非 LazyVStack 卡片上，因此源卡片滚出渲染区域后识别器仍保持 active，直到用户真正松手或系统取消；0.3 秒内移动超过 12pt 会在识别前失败，由页面滚动完整接管，长按成功后移动超过 3pt 才进入拖卡状态。独立的左滑操作使用带 `UIGestureRecognizerDelegate` 方向门控的 `UIPanGestureRecognizer`，长按和左滑互相禁用。主列表通过零高度 `UIViewRepresentable` 定位其 `UIScrollView`：拖卡时只禁用 scroll view 的手动 pan，16ms 循环仍直接更新 `contentOffset`。手指进入上下 72...110pt 边缘区后以 90...720pt/s 连续滚动，速度按边缘接近度的 1.55 次曲线变化；滚动期间持续修正目标日期和插入位置。
- Verification: 单测覆盖 3pt 激活阈值、中心零速度、上下方向、越靠边越快、最大速度，以及手动 pan 锁定时仍可程序化滚到上下边界；Debug 模拟器构建验证根层识别器与 UIScrollView 桥接。

### Task 6: 列表卡片 UI 与左滑编辑/Agent/删除
- Files: `ItineraryView.swift`、`Assets.xcassets/icon-chat-outline.imageset/*`、`Assets.xcassets/icon-delete-outline.imageset/*`、`TravelCardsTests.swift`
- Implementation: 普通卡片使用 64pt 圆角封面与右侧信息栏，标题使用 19pt semibold，时间和单一优先价格分别复用 `icon-pin-outline`、`icon-ticket-outline`，描述/备注最多四行并置于独立深色圆角摘要区。`showLargeImage=true` 且封面路径有效时改用 12pt 外部内边距、38:21 横图、底部渐变、标题和元信息叠层；存在描述、备注或提示时，在图片下方间隔 12pt 显示最小高度 102pt 的独立摘要区，不存在时不预留摘要高度。旧数据和低分图片保持普通卡片。左侧 4pt 橙色条由全行程时间判定标记当前活动，空档期标记最近下一项，30 秒刷新一次，拖动副本继承相同状态。在卡片后方放置三个最终宽度各 68pt 的操作按钮，编辑使用 `icon-edit-outline`，Agent 使用用户提供的 `icon-chat-outline`，删除使用 `icon-delete-outline`。三层按钮的位置分别按当前展开宽度的 2/3、1/3、0 移动，因此从首段左滑开始按 1:1:1 同步展开，而不是依次出现；横向偏移限制在 0...204pt。原生横向 pan 的速度方向达到 1.25 倍纵向速度且向左时才接管，按预测终点与 42% 阈值吸附，展开时允许向右关闭。编辑复用 `CardEditorTarget.edit`；Agent 复用 `AgentWorkbenchView.initialMessage`，只预填所选卡片日期/标题/时间/地点；删除复用现有确认框与 `SyncEngine.deleteCard`。
- Verification: 单测覆盖横纵方向判定、204pt 左右边界、三等分同步展开几何、Agent 卡片上下文和展开阈值；资产编译、Debug 构建与模拟器展开态截图验证。

### Task 7: 后端图片最终评分与大图决策
- Files: 后端 `app/services/poi_images.py`、`app/models.py`、`app/schemas.py`、`migrations/versions/v0012_card_image_display_score.py`，客户端 `SharedModels.swift`、`ItineraryView.swift`
- Implementation: 在既有候选相关度和位图画质分之上，以 50% 相关度、30% 画质、15% 横向封面适配度和 5% 可用候选丰富度生成 0...100 的 `imageScore`。默认阈值 82，达到阈值才写入 `showLargeImage=true`。无候选、失败任务、用户自带图和迁移前旧数据默认 0/false；客户端只服从布尔字段，不重复阈值判断。
- Verification: 后端单测覆盖高相关横图高分、边缘相关竖图低分、接口序列化和迁移；客户端单测覆盖新字段与旧缓存兼容，以及当前/下一项唯一选择。

## API/Data Changes
- `GET`/写操作回传的 card 增加只读 `imageScore: Int (0...100)` 与 `showLargeImage: Bool`。
- `itinerary_cards` 增加 `image_score` 与 `show_large_image`，由迁移 `0012_card_image_display_score` 建立；写卡 API 不接受客户端修改这两个字段。
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
