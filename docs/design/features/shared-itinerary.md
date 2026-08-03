# Feature Implementation: 唯一共享行程

## Goal
App 启动即进入固定的一份共享行程，按日期呈现可离线浏览和编辑的时间轴；不提供任何行程列表、归档或多行程入口。

## Files
- Create: `Sources/TravelCompanion/Core/{APIClient,SyncEngine,APIModels}.swift`、`Sources/TravelCompanion/Data/{SharedModels,SharedTripRepository}.swift`、`Sources/TravelCompanion/Features/Itinerary/{ItineraryView,TripSetupSheet,DayEditor}.swift`；后端 `app/{extensions,models,schemas,errors}.py`、`app/routes/trip.py`、`app/services/sync.py`、`tests/test_trip.py`。
- Modify: `Sources/TravelCompanion/TravelCompanionApp.swift`、`Sources/TravelCompanion/ContentView.swift`、后端 `app/__init__.py`、`requirements.txt`、`run.py`。

## Tasks

### Task 1: 单例行程 API 与版本模型
- Files: 后端 `app/models.py`、`app/schemas.py`、`app/routes/trip.py`、`app/services/sync.py`、`tests/test_trip.py`。
- Implementation: 建立固定 `SharedTrip(id=1)`、`TripDay` 和 `AppliedOperation`；`GET /v1/trip?afterVersion=` 返回完整快照或 204，`PATCH /v1/trip`、日期 POST/PATCH/DELETE 使用 `Idempotency-Key` UUID 与 `X-Expected-Trip-Version` 整数请求头。每次成功写递增 `trip.version`；落后版本照常最后写入优先并回传 `meta.conflict=true`。所有写入在事务中去重幂等键。
- Verification: `./.venv/bin/python -m pytest -q tests/test_trip.py` 覆盖首次初始化、204、重试幂等、过期版本和字段校验。

### Task 2: 本地镜像和唯一时间轴
- Files: iOS `SharedModels.swift`、`SharedTripRepository.swift`、`SyncEngine.swift`、`ItineraryView.swift`、`TripSetupSheet.swift`。
- Implementation: SwiftData 保存快照及当前 tripVersion；启动先渲染缓存再拉取单例。没有目的地/日期时显示同页初始化表单，保存后仍回到该行程。按 `TripDay.date/position` 分段，空日显示添加入口；所有编辑先本地乐观写入并创建 `PendingOperation`。
- Verification: Xcode 单元测试覆盖日期排序与本地合并；模拟器首启初始化、重启后仍显示，断网编辑显示待同步。

## API/Data Changes
- 服务端 `SharedTrip` 只允许一条 `id=1`；不设计 `GET /trips`、`POST /trips`。
- Day DTO：`{id,date:"YYYY-MM-DD",position,updatedAt}`；日期在同一行程唯一，删除含卡片的日期返回 `409 day_not_empty`，用户须先移动/删除卡片。

## Edge Cases
- 本机没有缓存且网络失败：显示“无法加载共享行程”和重试，不生成虚假第二行程。
- 幂等重试返回原响应；服务端无法识别 UUID 或日期/币种格式时返回字段错误。
- 公开 API 被外部改动时照常拉取并显示；不得把 `DeviceProfile` 当成权限校验。

## Human Verification
- 两台设备初始化/打开同一 API，新增日期和修改目的地，另一端 5 秒内看到相同时间轴；重启两端确认本地缓存和服务器一致。

## Done Criteria
- 不出现行程列表或多行程创建路径；单例行程、日期操作、缓存、离线队列和版本反馈均可运行并由 API/模拟器验证。
