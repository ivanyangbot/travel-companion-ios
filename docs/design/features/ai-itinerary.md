# Feature Implementation: AI 填入行程

## Goal
把用户提供的攻略文本转换为可编辑、可选择、必须确认后才写入共享行程的结构化草案。

## Files
- Create: iOS `Features/AI/{AIItinerarySheet,DraftEditorView}.swift`；后端 `app/routes/ai.py`、`app/services/ai.py`、`tests/test_ai.py`。
- Modify: iOS `Core/APIClient.swift`、`Data/SharedTripRepository.swift`；后端 `app/{config,schemas,__init__}.py`。

## Tasks

### Task 1: AI 代理与结构化校验
- Files: `app/routes/ai.py`、`app/services/ai.py`、`app/schemas.py`、`tests/test_ai.py`。
- Implementation: `POST /v1/ai/itinerary-drafts` 接收限长的 `sourceText,startDate,days,preferences`，通过 `AI_API_BASE_URL`、`AI_API_KEY`、`AI_MODEL` 调用兼容供应商；将输出严格校验为 `days[].cards[]`（kind/title/date/time/place/notes），失败返回 `502 ai_provider_error` 或 `422 invalid_ai_output`。草案和原文不落库，不写日志；按 IP 做基础限流。
- Verification: pytest 覆盖空/超长输入、供应商超时、无效 JSON、可用草案和无配置。

### Task 2: 草案预览与确认导入
- Files: `AIItinerarySheet.swift`、`DraftEditorView.swift`、`SharedTripRepository.swift`。
- Implementation: 输入保留在 Sheet 状态直至用户取消；草案可改、删、勾选。确认后将选中条目作为常规 cards/days 写操作排队（每个请求附带 `Idempotency-Key` 与 `X-Expected-Trip-Version`），取消或失败绝不写共享行程。
- Verification: 模拟器导入一段攻略后取消一次、确认一次；断网确认后检查队列恢复同步。

## API/Data Changes
- 草案 DTO 为临时响应，不新增数据库实体；不得接收或引用 `LocalWalletItem`。
- AI Key 仅 Flask 环境变量，响应不暴露模型密钥、完整供应商异常或提示词模板。

## Edge Cases
- 供应商输出日期超出旅行范围时标注并要求用户改正；不能自动覆盖已有卡片。
- 网络/限流失败保留输入与已编辑草案，并提供重试。

## Human Verification
- 粘贴真实攻略，确认结构化结果可编辑；分别取消和确认，核验取消零写入、确认在第二设备可见。

## Done Criteria
- AI 只生成临时草案，用户确认的卡片通过既有同步契约保存；密钥与卡包从不离开正确边界。
