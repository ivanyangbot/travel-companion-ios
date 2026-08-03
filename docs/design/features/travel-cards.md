# Feature Implementation: 旅行卡片与外部联动

## Goal
在唯一时间轴内创建、编辑、排序机票、酒店、活动三类共享卡片，并可复制、系统分享或安全地跳转外部 App/网页。

## Files
- Create: iOS `Features/Cards/{CardModels,CardEditorView,TravelCardView,ExternalLinkHandler}.swift`、`UI/Components/TravelCardStyle.swift`；后端 `app/routes/cards.py`、`tests/test_cards.py`。
- Modify: iOS `Features/Itinerary/ItineraryView.swift`、`Data/SharedTripRepository.swift`；后端 `app/{models,schemas,__init__}.py`。

## Tasks

### Task 1: 卡片共享 CRUD
- Files: 后端 `models.py`、`schemas.py`、`routes/cards.py`、`tests/test_cards.py`。
- Implementation: `ItineraryCard.kind` 限为 `flight|hotel|activity`；保存 `dayId,title,startAt,endAt,placeId,bookingCode,url,notes,position`。`POST /v1/cards`、`PATCH/DELETE /v1/cards/{id}` 均带 `Idempotency-Key` 和 `X-Expected-Trip-Version`；`place` 由卡片 DTO 内嵌创建或引用既有 place，避免额外 UI 工作流。
- Verification: 测试三种 kind、时间范围/链接长度校验、排序、缺失 day、删除与重复 operationId。

### Task 2: 卡片 UI、复制与外跳
- Files: `CardEditorView.swift`、`TravelCardView.swift`、`ExternalLinkHandler.swift`。
- Implementation: 依据 kind 呈现信息密度不同的卡片，不为飞猪/小红书私有链接编写抓取器。复制订单号/地址使用 `UIPasteboard` 并提示风险；系统分享用 `ShareLink`。仅接受 `https` 链接，尝试 `UIApplication.open`，失败/未装 App 时用 `SFSafariViewController` 或系统浏览器打开原网页。
- Verification: 模拟器创建每种卡片、编辑/删除/排序；单元测试 URL 白名单和显示字段；真机验证 ShareLink 与网页回退。

## API/Data Changes
- Card 响应包含 `{id,dayId,kind,title,startAt,endAt,place,bookingCode,url,notes,position,updatedAt}`，敏感支付字段不定义。
- 链接解析只是客户端展示辅助，原 URL 始终原样保存；无第三方 API Key 或账户字段。

## Edge Cases
- 链接无效时阻止提交并保留表单；可空 `bookingCode`、地点和结束时间。
- 远端删除正在编辑的卡片时保存得到 `404`，提示已不存在并刷新，而不是本地重建。

## Human Verification
- 为三类卡片分别测试新增、复制、分享和有效网页链接；关闭网络后编辑，恢复后在另一设备看到更新。

## Done Criteria
- 所有三类卡片可以在唯一行程中增删改排并同步；外部联动无私有 API 依赖，未安装目标 App 有可用网页回退。
