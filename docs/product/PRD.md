# Product Requirements Document

## Product Summary
- Product name: 同行（暂定）
- Target users: 计划一次旅行的两位 iPhone 用户。
- Primary problem: 行程、订单、攻略、路线、支出与常用号码分散在聊天与多个旅行 App，双人协作成本高。
- Core value: 围绕唯一共享行程，提供简洁的卡片化计划、支出、路线与本机私密卡包，并高效跳转常用旅行服务。

## Goals
- Must achieve: 唯一共享行程；机票、酒店、活动三类卡片；公开链接/系统分享联动；支出与双方平摊；本机卡包；AI 生成待确认草案；地点间距离、时长与地图路线；双设备同步。
- Nice to have: 图片、天气、收据、冲突提示、导出和本机 Face ID 解锁。
- Explicitly out of scope: 行程列表/多行程、账号体系、预订或支付、第三方私有 API、社区、后台运营、云端卡包、实时导航和多人权限。

## Platforms
- Target platforms: iOS 17+ 原生 SwiftUI App；Flask JSON API。
- Devices/browsers: iPhone 优先；无 Web 前台，iPad 适配不属 MVP。
- Offline/local-only expectations: 已加载行程可离线查看，编辑进入待同步队列；卡包可离线使用且仅本机保存；AI、路线和跨设备同步需网络。

## User Roles
- Role: 两位同等协作者。
- Permissions: 两台设备均可读写共享行程和支出；卡包只限创建它的本机；无管理员或账号角色。
- Key workflows: 首台设备初始化行程，第二台以预配置的公开资源标识访问；双方编辑卡片和支出后自动刷新；卡包只复制给系统剪贴板供外部 App 使用。

## Core User Journeys
1. 用户打开 App 即进入唯一行程，按日期和时间查看并管理卡片。
2. 用户创建机票、酒店或活动卡片，复制关键内容并经分享/链接跳转飞猪、小红书或地图。
3. 用户粘贴自然语言攻略，查看并编辑 AI 草案后确认导入。
4. 用户查看相邻地点距离与预计时长，并在地图 App 打开路线。
5. 用户登记支出，查看总额、分类与两人结算结果。
6. 用户在本机卡包复制护照号、订单号或会员号。
7. 两台设备在联网状态下同步共享行程和支出。

## Data And Storage
- Data entities: SharedTrip、TripDay、ItineraryCard、Place、RouteEstimate、Expense、DeviceProfile、PendingOperation、LocalWalletItem。
- Local data: SwiftData 缓存、离线操作、路线缓存、设备显示名；Keychain 保存本机配置，卡包使用受数据保护的本地存储。
- Cloud/server data: 仅共享行程、地点、卡片、支出、资源版本与最小设备元数据；绝不上传卡包、剪贴板或第三方账户凭据。
- Sync requirements: 前台短轮询；联网后用户操作立即刷新，另一端正常网络下 5 秒内可见；服务端版本号+最后写入优先，冲突提示后保留最近版本。
- Retention/privacy constraints: 共享数据保留到部署方清理；日志脱敏且不记录完整 AI 文本、资源标识或敏感号码；卡包不进服务端备份。

## Authentication And Accounts
- Login required: 否。
- Account providers: N/A。
- Guest mode: 所有设备为匿名设备。
- Authorization boundaries: 用户确认选择完全公开、无访问控制；知道接口/资源标识的任何调用者可读取和写入共享数据。该选择不适用于敏感共享资料；卡包仍只在本机，生产环境仍需 HTTPS、限流、CORS 和输入校验。

## Feature List
| Feature | User Value | Inputs | Outputs | Boundary | Acceptance Criteria |
| --- | --- | --- | --- | --- | --- |
| 唯一共享行程 | 两人管理一次旅行 | 日期、目的地、卡片 | 按日时间轴 | 无列表/多行程 | 首次启动直接进入一份行程；增删改重启后保留并同步 |
| 首页行程列表与分层吸顶 | 用户长距离浏览每日行程时，始终知道当前行程、可切换日期，并保持当前日期语境 | 共享行程标题、地图模式既有时间轴、按日行程数据与当日总结 | 按长图样式呈现的分日卡片列表、固定的行程标题与时间轴、当前日期吸顶标题 | 完整复用地图模式时间轴的内容、样式、选中态和交互；不重做地图时间轴，不新增筛选/折叠，不改变行程数据结构、同步或 API；不包含横屏与 iPad 专属布局 | 列表模式下标题与时间轴组成无重叠的顶部固定区；时间轴与地图模式显示及交互一致；“日期＋星期＋当日总结”标题到达时间轴下方后吸附，持续到相邻日期标题将其替代；滚动、切日和模式切换时日期语境一致且内容不卡跳 |
| 旅行卡片与联动 | 集中保存订单和攻略 | 类型、时间、地点、链接、备注 | 三类卡片、复制/外跳 | 无预订/私有抓取 | 三类卡片均可编辑、复制、系统分享与网页回退 |
| 地图与路线 | 判断景点衔接 | 两个地点、交通方式 | 距离、时长、导航入口 | 无内置导航 | 已定位地点返回结果或可理解错误；可打开路线 |
| 支出统计 | 双人对账 | 金额、类别、付款人、分摊 | 总额、分类、净额 | 单一主要币种 | 增删改即时更新，平摊结果可解释 |
| 本机卡包 | 复制常用号码 | 标签、号码、备注 | 遮挡显示、复制 | 不上传/不同步 | 可管理条目且另一端/服务端不可见 |
| AI 填入行程 | 攻略变草案 | 文本、日期、天数 | 可编辑预览 | 需确认后写入 | 失败不丢输入，确认后生成并同步卡片 |
| 双人协作 | 同一计划可见 | 共享修改 | 自动刷新、状态 | 最多两台设计目标 | 正常网络下变更 5 秒内可见 |
| 首页 Pin 动态边界与无重叠聚合 | 在地图移动中稳定辨认屏内与屏外行程地点 | 既有 Pin placement、动态安全区 | 普通/吸边 Pin、无重叠聚合与直接终态拆分 | 不接入 Gooey、metaball、液态桥、延迟补播或临时视觉副本 | resolver 结果直接显示；成员、位置、标签、选择、相机和地图手势保持稳定 |
| Pin Gooey 视觉调参 Demo | 独立验证轮廓与数字成员的融合样式 | 两枚 Pin 二维位置、静态数字场景、滤镜/状态参数 | 360° 实时轮廓、首页同规则自适应宽度与稳定数字顺序融合/分离预览 | 不接地图、POI、业务数字、网络或持久化 | 两 Pin 均可自由拖动；成员按相对位置稳定排序且分离无离散跳变；32pt 等高；Debug 构建通过 |

## UX Requirements
- Navigation: 根页为行程；底部为行程、支出、卡包；AI、地图、邀请/设置通过 Sheet 或工具栏进入，不出现行程列表。
- Main screens/pages: 首页支持地图与列表两种查看模式；列表模式按日期连续呈现卡片，视觉层级和信息密度遵循需求长图；另有卡片编辑、AI 草案、路线 Sheet、支出统计、卡包、基础设置，开发期可由设置齿轮打开独立 Pin Gooey 视觉调参 Sheet。
- List sticky hierarchy: 列表滚动时，“麗江奶龍之旅測試文字”所代表的行程标题固定在页面顶部，其下完整复用首页地图模式时间轴并固定；两者构成稳定的顶部吸顶区，不互相遮挡，也不遮挡系统安全区或可操作控件。
- Day sticky header: 每日分组以“09.12 六 抵達麗江，古城夜遊（8字當日總結）”同等结构显示日期、星期和当日总结；分组标题滚动至时间轴下缘时吸附在其下方，并保持到下一天标题从下方推入并替代；反向滚动时按同样规则由上一天标题替代。
- Timeline consistency: 列表模式不得创建内容或行为不同的简化时间轴；日期顺序、当前日期标识、选中态、可滚动范围、点击切日结果及地图/列表模式切换后的选中日期均与首页地图模式一致。点击时间轴日期后，列表滚动到对应日期分组，且该分组标题最终停留在时间轴下方。
- Empty/loading/error states: 空日期提供添加入口；AI、地图、同步显示加载、上次同步、重试和不丢输入的错误状态。
- Accessibility/localization: 动态字体、VoiceOver、44pt 点击区域、非颜色唯一状态表达；列表分层吸顶在大号动态字体下仍无文字截断或层级重叠，VoiceOver 阅读顺序保持标题、时间轴、当前日期标题、当日卡片；首页聚合/拆分始终直接呈现稳定 Pin，命中和辅助功能树中不存在临时视觉副本；MVP 简体中文，预留本地化。

## API And Integration Requirements
- External services: 高德地点/路线服务与 iOS URL Scheme；飞猪、小红书等的系统分享、公开链接和网页回退；兼容的 LLM API。
- Server-side secrets: LLM Key 和高德 Web Service Key 只在 Flask 环境变量；iOS 地图 Key 按 Bundle ID 限制。
- Payment/notification/maps/AI requirements: 无支付和推送；AI 输出必须为结构化草案并由用户确认；地图结果有来源与更新时间；不得发送卡包给任何服务。
- Admin or analytics requirements: 无后台；只允许最小匿名故障指标，不采集完整行程和卡包内容。

## Operational Requirements
- Deployment target: 开发期本机 Flask+PostgreSQL；生产环境和域名待用户提供。
- Domain/DNS: 发布前使用 HTTPS；不在本阶段变更 DNS。
- Health checks: `GET /health` 返回不含业务数据的服务和数据库状态。
- Logging/monitoring: 记录请求 ID、路由、状态、耗时与匿名错误码；脱敏资源标识、AI 文本和敏感字段。
- Backup/restore: 服务端数据库由部署环境定期备份；卡包不备份到服务端。

## Release Requirements
- Web publish: N/A。
- App build: Xcode Debug build 和 Simulator/真机核心流程验证。
- TestFlight/App Store/Android distribution: 默认仅交付 Xcode 工程与 Flask 服务；TestFlight 与 App Store 后续另行授权。
- Manual approvals: 提供高德与 AI 凭据、生产部署位置/域名；发布前完成双设备、外跳和隐私验收。

## Risks And Assumptions
- Assumptions: 两名互相信任的 iPhone 用户、一次旅行、主要在中国大陆；可接受公开共享 API 风险。
- Risks: 完全公开 API 可被读取/篡改；AI 可能出错；第三方链接规则会变化；地图时长不保证精确；最后写入优先会覆盖并发编辑；独立 Gooey Demo 不得进入首页地图渲染、annotation 生命周期或业务状态机；标题、时间轴与日期标题的多层吸顶在小屏幕、刘海安全区或大号动态字体下可能出现遮挡、抖动和可视区域过窄；时间轴点击定位与手势滚动若双向更新不一致，可能造成日期选中态跳变或列表回弹。
- Decisions still pending: AI 供应商与预算、高德 Key、生产部署、目的地/日期/默认币种，以及是否允许清空重建唯一行程。
