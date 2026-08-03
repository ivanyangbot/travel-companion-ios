# Product Feature: 旅行卡片与外部联动

## Description
以机票、酒店、活动/景点卡片保存旅行信息，并用复制、系统分享和公开链接高效联动外部旅行应用。

## Inputs
- 类型、标题、时间、地点、订单号、链接、备注和来源。

## Outputs
- 可编辑三类卡片；复制关键字段；打开 App、网页或系统分享页。

## Boundary
### Included
- 三种卡片、通用链接保存、分享扩展接收入口、URL Scheme/网页回退。
- 小红书链接导入：服务端读取 note 页公开 og 元数据，下载首图托管为 `/v1/files/<name>`，AI 据标题/描述生成单卡字段（kind/title/place/notes），用户确认后保存。

### Excluded
- 预订、支付、登录飞猪/小红书、抓取受限内容。仅读取小红书公开分享预览元数据，不解析 JS 动态内容。

## Acceptance Criteria
- 三类卡片可增删改排序；链接解析失败仍保存原链接；目标 App 未安装时可网页或分享回退。
- 粘贴或经分享扩展传入小红书链接时，编辑器可触发“AI 读取小红书”自动回填类型/标题/地点/备注/封面图；抓取失败给出提示且不阻塞手动填写；原图下载失败时仍返回字段（封面图留空）。

## Data And Permissions
- Data touched: ItineraryCard、Place、外部链接元数据。
- Owner: 共享行程数据由双方共同编辑。
- Permission/auth expectations: 公开共享 API；不得上传本机卡包。

## UX Notes
- Screens/pages: 卡片列表、详情、紧凑编辑表单、外部跳转 Sheet。
- Empty/loading/error states: 空卡片、链接无法解析、外部 App 不可用、保存失败。
- Human verification: 分别创建三类卡片，测试复制、分享和网页回退。

## Open Questions
- 飞猪等其他平台的链接导入是否复用同一 `/v1/ai/link-import` 通道及各自的 og 元数据格式（已落地小红书：`xiaohongshu.com`、`xhslink.com`）。
