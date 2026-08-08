# Feature Implementation: 小红书 POI 导入与 Agent 调度

## Goal

在现有 SwiftUI + Flask Agent v2 架构内，安全读取公开小红书笔记并把具体 POI 转换为经过来源绑定、Apple Maps 验证且必须由用户确认的行程候选。本期采用标准库 HTML 解析，不引入登录态、签名 API、浏览器运行时或新数据库表。

## Files

- Create:
  - `docs/product/features/xiaohongshu-poi-import.md`
  - `docs/design/features/xiaohongshu-poi-import.md`
  - `tests/fixtures/xiaohongshu_initial_state.html`
  - `tests/fixtures/xiaohongshu_mobile_state.html`
- Modify:
  - Backend `app/services/link_import.py`
  - Backend `app/services/agent_v2.py`
  - Backend `app/routes/agent_v2.py`
  - Backend `tests/test_link_import.py`
  - Backend `tests/test_agent_v2.py`
  - iOS `Sources/TravelCompanion/Features/AI/AgentWorkbenchView.swift`
  - iOS `Sources/TravelCompanion/Features/Itinerary/ItineraryView.swift`
  - iOS `Sources/TravelCompanion/Features/Cards/PendingSharedLinkStore.swift`

## Tasks

### Task 1: 安全的公开笔记解析

- Files: `app/services/link_import.py`, `tests/test_link_import.py`, HTML fixtures。
- Implementation:
  - 从整段分享文案提取最多 3 个 HTTPS 小红书链接并清理中文尾随标点。
  - 自定义重定向处理；每跳和最终 URL 都校验白名单域名，并拒绝 IP、localhost 和私网解析结果。
  - 在 2 MiB/10 秒边界内读取 HTML。
  - 用 `HTMLParser` 定位脚本，再做字符串感知的 `undefined → null` 规范化；解析桌面端 `note.noteDetailMap` 与移动端 `noteData.data.noteData`。
  - 从状态提取 note id、标题、正文、作者、标签和最多 8 个图片 URL；缺失时用 OG 兜底。
  - 解析成功条件是标题或正文可用，图片为可选。
- Verification: fixture 单元测试覆盖标准结构、移动端、正文含 `undefined`、OG-only、无图片、非法链接和跳转边界。

### Task 2: Agent 工具调度与来源信任边界

- Files: `app/services/agent_v2.py`, `app/routes/agent_v2.py`, `tests/test_agent_v2.py`。
- Implementation:
  - 增加 function tool `xiaohongshu_note_tool(url)`；单 turn 最多读取 3 个不同链接并缓存结果。
  - 直接分享链接在进入 provider 前确定性预解析；搜索路径保留 `web_search`，模型找到 URL 后必须调用读取工具。
  - 成功工具结果签发随机 `sourceRef`，正文限制为 12,000 字符，不返回原始 HTML 或上游异常。
  - card XML 新增可选 `sourceRef`；路由只接受本轮证据中的引用，并用 canonical URL 覆盖模型输出 URL。
  - 小红书证据只提供内容来源；地点身份和坐标仍由 `map_search_tool` 与现有验证代码决定。
  - SSE 把小红书工具开始/完成映射为现有 `status`，无需客户端协议升级。
- Verification: 工具 schema、调用回放、缓存/上限、直接预取、伪造 URL/ref、来源绑定和 map evidence 组合测试。

### Task 3: iOS 分享入口可靠交接

- Files: `AgentWorkbenchView.swift`, `ItineraryView.swift`, `PendingSharedLinkStore.swift`。
- Implementation:
  - `AgentWorkbenchView` 接收可选初始消息，并只在输入为空时消费一次。
  - `ItineraryView` 把待分享 URL 转成明确的小红书解析提示传入 Agent。
  - 只有初始消息已写入本地 Agent 会话、即将发送时才 `markDelivered()`；持久化链接在此时清除，避免仅预填后退出或崩溃导致链接丢失。
  - 增加小红书分享/搜索快捷提示，不新建页面。
- Verification: Swift 单元测试覆盖初始消息规范化/幂等消费；Xcode build/test 验证分享扩展与主 App。

## API/Data Changes

- 外部入口保持 `POST /v2/agent/turns/stream` 和既有 SSE 协议。
- Provider tools 新增内部函数：

```json
{
  "type": "function",
  "name": "xiaohongshu_note_tool",
  "parameters": {
    "type": "object",
    "properties": {"url": {"type": "string"}},
    "required": ["url"],
    "additionalProperties": false
  }
}
```

- 成功工具结果（仅本轮内存）：

```json
{
  "ok": true,
  "sourceRef": "server-generated-uuid",
  "note": {
    "noteId": "optional",
    "canonicalUrl": "https://www.xiaohongshu.com/explore/...",
    "title": "optional",
    "author": "optional",
    "text": "bounded",
    "tags": ["bounded"],
    "imageURLs": ["bounded"],
    "parserMode": "initial_state|open_graph"
  }
}
```

- Agent card XML 增加可选 `<sourceRef>`。它只用于服务端匹配内存证据，不进入数据库。
- 无 schema migration。提交后只复用现有 `ItineraryCard.url`；原始 HTML/正文/作者/来源证据均不持久化。
- 兼容旧 `POST /v1/ai/link-import`；丰富的 `NoteContent` 保留原有四个构造字段。

## Security And Licensing

- 页面内容视为提示注入不可信数据；系统提示明确禁止执行正文指令。
- URL 获取执行 HTTPS、域名、DNS/IP、逐跳重定向、响应大小和超时校验。
- 日志不包含完整 URL query、正文、作者或 token。
- 算法借鉴 Apache-2.0 `jackwener/xhs-cli` 和 `xpzouying/xiaohongshu-mcp` 的公开状态解析思路，并在本项目中独立实现。
- 不复制 GPL-3.0 XHS-Downloader 代码，不引入 MediaCrawler 的非商业限制代码，也不把 MIT `xhshow` 签名 API作为 P0 依赖。

## Edge Cases

- 分享文本含 emoji、多行文字、中文句号/括号或多个链接。
- 短链跳转到非白名单域名、IP/私网，重定向循环或超过跳转上限。
- 页面为验证码、登录、私密、删除或响应过大。
- 状态脚本缺失、`undefined` 同时出现在正文字符串和对象值中、Vue value 包装。
- 一篇笔记无图片、只有 OG 预览或没有具体 POI。
- web search 不支持；回退时仍保留小红书读取工具与现有地图验证。
- 模型输出伪造 URL、未知 `sourceRef` 或来源与候选不匹配。
- 多个 POI 同名、Apple Maps 无匹配、行程版本冲突和重复幂等提交。

## Human Verification

- 在模拟器从 Agent 粘贴一段小红书分享文案，检查输入、读取状态、候选来源链接和地图验证标识。
- 从系统分享扩展进入，确认 Agent 输入已预填且退出/重开前不会过早丢失。
- 取消本轮后检查行程无新增；选择候选并确认后检查卡片来源 URL 可打开。
- 用网络失败和无效链接检查输入保留、错误状态和无数据库写入。

## Done Criteria

- 产品和技术功能文档与代码一致。
- 解析器和 Agent 新测试通过，原有 95 个相关后端测试无回归。
- 后端完整 pytest 通过。
- iOS 单元测试和模拟器构建通过。
- `git diff --check` 无格式错误；代码评审没有遗留高风险项。
- 没有部署、提交、推送或修改生产环境。
