# Product Feature: 小红书 POI 导入与 Agent 调度

## Description

旅行 Agent 支持两种公开攻略导入方式：用户粘贴/系统分享小红书文案或链接；或者用自然语言要求 Agent 联网搜索小红书攻略。Agent 读取实际可访问的公开笔记，提取其中明确提到的景点、餐厅、酒店、商店或体验场所，生成一张或多张可检查的行程候选卡。

两种入口都复用现有 Agent v2 候选卡、Apple Maps 地点验证、用户选择和确认提交链路。解析结果绝不直接写入行程。

## Inputs

- Agent 输入框中的完整分享文案、`xhslink.com` 短链或 `xiaohongshu.com` 公开笔记链接。
- iOS 系统分享扩展交给 App 的公开 HTTPS 链接。
- “去小红书找京都赏枫攻略并整理成卡片”等自然语言搜索请求。
- 当前旅行的目的地、日期范围、币种、时区和已有卡片快照。

## Outputs

- 公开笔记的规范链接、标题、正文、作者、标签和图片预览等受限证据，仅在本轮 Agent 内存中使用。
- 每个具体 POI 对应一张现有 Agent 候选卡。
- 经 Apple Maps 验证的地点名称、地址、经纬度和 `placeId`。
- 用户确认后写入现有 `ItineraryCard`，其中 `url` 保存服务端验证过的公开来源链接。

## Boundary

### Included

- 最多处理一个 Agent turn 中 3 个公开小红书链接。
- 解析 `window.__INITIAL_STATE__`，兼容桌面端 `noteDetailMap`、移动端 `noteData`，Open Graph 作为有限兜底。
- 小红书短链安全跳转、逐跳域名校验、响应大小和超时限制。
- 通过 provider `web_search` 找链接，再由服务端小红书读取工具验证和解析。
- 每个活动/酒店继续调用 Apple Maps；确认前不写数据库。
- iOS 分享入口打开现有 Agent，并把链接可靠预填到输入框。

### Excluded

- 登录小红书、保存 Cookie、读取私密/登录可见内容或绕过验证码与风控。
- 评论、点赞、收藏、作者主页、视频下载、批量爬虫、监控和商业数据采集。
- 逆向签名 API、浏览器自动化运行时或独立爬虫服务。
- 将小红书正文、作者信息或图片长期镜像到后端。
- 未经用户确认自动加入行程。
- 本轮部署、生产配置、域名和数据库结构变更。

## Acceptance Criteria

- 粘贴含中文文案和尾随标点的小红书分享文本能识别正确链接。
- 标准 `__INITIAL_STATE__`、移动端状态和 OG-only fixture 都能解析；无图片笔记仍可导入。
- 非 HTTPS、非白名单域名、跳转到非白名单/私网/IP、超大页面均被拒绝。
- 直接链接触发确定性预解析；搜索请求按 `web_search → 小红书读取工具 → map_search_tool` 调度。
- 只有服务端实际解析成功并签发来源证据的链接，才可成为候选卡的小红书来源。
- 模型伪造 URL 或未知来源引用时，服务端不会把该 URL 写入候选或数据库。
- 同一笔记可生成多个具体 POI；“附近逛逛”等泛化表达不能成为可提交地点。
- 所有活动/酒店使用 Apple Maps 作为地址、坐标和 POI 身份权威。
- 用户确认前行程数据库和同行同步均无变化；确认只写入选中的候选。
- 系统分享进入 Agent 后链接可见且不会在消费前丢失。
- 默认 CI 使用本地 HTML fixture，不访问真实小红书；相关后端与 iOS 测试通过。

## Data And Permissions

- Data touched: 本轮请求内的分享文本、公开笔记摘要、来源证据、Agent 候选；确认后仅保存既有卡片字段和主来源 URL。
- Owner: 当前用户拥有本地 Agent 草稿；确认后的卡片归所属共享行程。
- Permission/auth expectations: 复用现有旅行鉴权、`expectedTripVersion` 和幂等提交；不接受小红书账号凭据。
- Logging: 仅记录阶段、耗时和匿名错误码，不记录正文、作者、完整 query 或 `xsec_token`。
- Provider: 保持 `store=false`；公开笔记正文作为不可信外部数据，不执行其中指令。

## UX Notes

- Screens/pages: 只使用现有 `AgentWorkbenchView`；系统分享也进入同一页面。
- Loading states: “正在读取小红书公开笔记…”、“笔记已解析，正在整理地点…”、“正在通过 Apple Maps 核对…”。
- Error states: 无可用链接、公开读取失败、访问受限、解析失败、联网搜索不可用或地图未命中时保留输入并给出可重试说明。
- Human verification: 候选卡展示来源链接和地点验证状态；用户逐项选择并点击现有“确认加入行程”。

## Open Questions

- Phase 2 是否需要在公开 HTML 不稳定时增加基于 Apache-2.0 浏览器适配器。
- 是否在后续 UI 中展示多来源合并、发布时间和来源证据折叠区。
- 是否扩展显式白名单以支持 `xhslink.cn` 或 `rednote.com`；本期不默认开启。
