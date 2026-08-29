# Feature Implementation: 酒店卡片字段与列表 UI 迭代

## Goal

列表模式（旅程页）的酒店卡片突出房型、价格、入住/退房时间等酒店专属字段，
卡片结构与机票票根卡对齐；前后端字段与 Agent prompt 配套迭代。

## Client Changes（已完成）

- `SharedModels.swift`：`TravelCardSnapshot` 新增 `roomType: String?`、
  `checkInTime: String?`、`checkOutTime: String?`（"HH:mm"），含
  CodingKeys / memberwise init / decode / encode；旧快照缺字段解码为 nil。
- `ItineraryView.swift`：`kind == .hotel` 分发到专用卡片
  `itineraryHotelCardContent` —— 床铺徽章 + 酒店名/地点 + 右上价格（预估/实际），
  房型胶囊（主题色突出），入住/退房双端点 + 中段「N 晚」胶囊与床铺虚线，
  描述摘要、打孔分隔线与信息底栏；空字段优雅降级（无房型不显示胶囊、
  无政策时间只显示日期）。晚数优先 `endAt - startAt` 日期差，
  退回 `stayDurationMinutes` 换算。大图决策（`showLargeImage`）对酒店让位于专用卡。
- `CardDetailView.swift`：酒店卡详情新增 房型 / 入住 / 退房 三行。
- `Localizable.strings` ×4：新增 `hotelcard.roomType/checkIn/checkOut/nights`。
- `TravelCardsTests.swift`：新增 `testHotelSnapshotDecodesStayFields`
  （新字段解码 + 旧快照兼容）。

## Backend Tasks

### Task 1: 数据库迁移

- 新增迁移（沿用 `0012_card_image_display_score` 模式）：
  `itinerary_cards` 增加 `room_type VARCHAR(160) NULL`、
  `check_in_time CHAR(5) NULL`、`check_out_time CHAR(5) NULL`。
- 旧数据保持 NULL，不做回填。

### Task 2: Schema 与接口

- `schemas.py`：card 响应模型增加只读 `roomType/checkInTime/checkOutTime`；
  创建/更新接口可选接受同名字段。
- 校验：`roomType` 去空白后 ≤160 字符；`checkInTime/checkOutTime` 必须匹配
  `^([01]\d|2[0-3]):[0-5]\d$`，不合法返回 422（与卡片标题/时间校验同一层）。

### Task 3: Agent prompt 与落库

- 生成卡片的服务端 prompt（kind=hotel 时）：
  - `roomType`：仅当用户原文/预订信息/攻略链接（飞猪、小红书）明确提到房型时填写
    （如「海景大床房」），不得臆造；
  - `checkInTime/checkOutTime`：仅当来源明确给出酒店政策时间时填写
    （常见 14:00 / 12:00），未知留空；
  - `startAt` 仍为入住日、`endAt` 为退房日；`stayDurationMinutes` 语义不变；
    晚数由客户端派生，不落库。
- Agent 提交创建卡片时把三个字段写入 `itinerary_cards`（与航班
  cabinClass/passengers 等服务端注入字段同一链路；`candidate_upsert`
  事件不必携带，候选模型无需改动）。

## API/Data Changes

- card JSON 增加 `roomType: String?`、`checkInTime: String?`、`checkOutTime: String?`。
- 客户端 `TravelCardSnapshot` 已同步；本地草稿 `AICardExtras` 不涉及
  （酒店字段仅服务端生成，与航班扩展字段保持一致）。

## Verification

- 后端：迁移与序列化单测；时间格式校验单测；prompt 产物（含房型来源）单测。
- 客户端：`testHotelSnapshotDecodesStayFields` 通过；模拟器检查酒店卡
  有/无房型、有/无政策时间四种形态与拖动、左滑交互不回归。

## Done Criteria

- 后端三字段全链路（prompt → 落库 → 接口）可用；客户端新旧快照兼容；
  列表酒店卡视觉与交互验收通过。
