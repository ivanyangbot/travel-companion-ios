# Product Feature: 支出统计与结算

## Description
记录旅行支出并实时展示总额、分类和两人应收应付。

## Inputs
- 金额、主要币种、类别、付款人、分摊方式、日期、备注和关联卡片。

## Outputs
- 支出明细、总额、分类统计、已付和净结算。

## Boundary
### Included
- 新增、编辑、删除、两人平摊与单人承担。

### Excluded
- 支付、报销审批、多币种实时换汇和复杂分摊。

## Acceptance Criteria
- 非法金额被拦截；增删改即时更新；平摊和单人承担的结算数字可解释且同步。

## Data And Permissions
- Data touched: Expense、类别、关联卡片、计算结果。
- Owner: 双方共享。
- Permission/auth expectations: 公开接口，禁止存储支付凭证。

## UX Notes
- Screens/pages: 支出清单、编辑表单、统计/结算页。
- Empty/loading/error states: 空支出、金额校验、保存失败、离线待同步。
- Human verification: 两人分别录入付款，手算并对照结算。

## Open Questions
- 主要结算币种和成员昵称。
