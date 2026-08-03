# Product Feature: 本机私密卡包

## Description
在设备上保存和复制护照号、订单号、会员号等常用旅行号码。

## Inputs
- 标签、号码/文本、备注。

## Outputs
- 遮挡显示的条目、复制动作与确认提示。

## Boundary
### Included
- 新增、编辑、删除、隐藏/显示、复制。

### Excluded
- 云端同步、共享、护照图片/OCR、银行卡 CVV、支付密码。

## Acceptance Criteria
- 可管理和复制条目；重启后保留；服务端与另一端无法获取卡包内容。

## Data And Permissions
- Data touched: LocalWalletItem、本机密钥和设备受保护存储。
- Owner: 仅创建者的设备。
- Permission/auth expectations: 不调用后端；复制提示剪贴板风险。

## UX Notes
- Screens/pages: 卡包列表、编辑 Sheet、复制反馈。
- Empty/loading/error states: 空卡包、复制失败、删除确认。
- Human verification: 在一台设备创建卡包项，确认另一端和网络请求均无内容。

## Open Questions
- MVP 是否启用 Face ID 二次解锁。
