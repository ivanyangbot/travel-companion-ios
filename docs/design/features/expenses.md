# Feature Implementation: 支出统计与结算

## Goal
记录共享旅行支出，以主要币种实时显示总额、分类金额及两个匿名协作者之间的净结算。

## Files
- Create: iOS `Features/Expenses/{ExpenseModels,ExpenseListView,ExpenseEditorView,ExpenseSummaryView}.swift`；后端 `app/routes/expenses.py`、`tests/test_expenses.py`。
- Modify: iOS `ContentView.swift`、`Data/SharedTripRepository.swift`；后端 `app/{models,schemas,__init__}.py`。

## Tasks

### Task 1: 支出 API 与确定性结算
- Files: 后端 `models.py`、`schemas.py`、`routes/expenses.py`、`tests/test_expenses.py`。
- Implementation: Expense 使用 `amountMinor` 正整数，币种必须等于 trip.currency，`paidBy` 取 `personA|personB`，`splitMode` 取 `equal|self`；POST/PATCH/DELETE 均带 `Idempotency-Key` 和 `X-Expected-Trip-Version`。统计由客户端基于完整快照计算，避免增加易过期统计 API：`equal` 使每人应付一半，`self` 使付款人全额承担；`net=paid-share`，负值者向正值者支付其绝对值。
- Verification: 单元测试金额边界、枚举、卡片可选关联、幂等写和两人手算案例。

### Task 2: 支出表单、统计与同步反馈
- Files: `ExpenseListView.swift`、`ExpenseEditorView.swift`、`ExpenseSummaryView.swift`。
- Implementation: 使用 `Decimal` 输入后精确转换为最小单位；列表按日期降序，摘要显示总额、分类和“甲应收/乙应付”的单条结论。成员名称读取本机设置，未设置时用“成员 A/B”，名称仅显示不当作账户。提交走共享仓储与 PendingOperation。
- Verification: iOS 单元测试结算函数与金额格式；模拟器录入双方付款、编辑、删除后即时更新。

## API/Data Changes
- Expense DTO：`{id,amountMinor,currency,category,paidBy,splitMode,occurredOn,note,cardId,updatedAt}`；不接收银行卡、支付渠道凭据或收据图像。
- 类别 MVP 固定 `transport|lodging|food|tickets|shopping|other`，界面提供中文映射。

## Edge Cases
- 金额为 0、负数、超出 Int64 或小数精度不合法时本机和服务端均拦截。
- 单一币种 MVP：不自动换汇；行程币种已存在支出后不可直接变更，返回 `409 currency_locked`。

## Human Verification
- A 付 100 且平摊、B 付 60 且自付，核对 A 应收 50、B 应付 50；在第二台设备确认同步结论一致。

## Done Criteria
- 有效支出可同步增删改，统计精确且可解释；无支付/银行卡数据和多币种换汇功能。
