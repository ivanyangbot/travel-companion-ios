# Product Feature: AI 填入行程

## Description
将自然语言旅行计划或粘贴攻略转换为可编辑、需确认的日程草案。

## Inputs
- 攻略文本、开始日期、天数、可选偏好。

## Outputs
- 按日期组织的卡片草案、错误说明、选择性导入结果。

## Boundary
### Included
- 文本输入、后端 AI 代理、结构化草案、编辑、确认和取消。

### Excluded
- 未确认时直接覆盖行程、访问卡包、自动预订、持续后台规划。

## Acceptance Criteria
- 有效输入返回草案或明确失败；取消不改行程；确认后选中卡片保存并同步；原输入在失败后保留。

## Data And Permissions
- Data touched: 临时提示词、AI 草案、ItineraryCard。
- Owner: 草案本机可编辑，确认后共享。
- Permission/auth expectations: AI Key 仅在 Flask；不得发送卡包；请求限长与限流。

## UX Notes
- Screens/pages: AI 输入、加载、草案预览/编辑、确认 Sheet。
- Empty/loading/error states: 空输入、超时、结构化输出失败、网络错误和重试。
- Human verification: 导入一段攻略，取消一次、确认一次，核验行程。

## Open Questions
- 选定 AI 供应商、模型、预算和数据跨境策略。
