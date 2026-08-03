# 分享扩展链接交接

`TravelCompanionShareExtension` 仅接受没有 URL 凭据、且主机为公开地址的 HTTPS URL。
它拒绝 localhost、私有、回环与链路本地 IPv4/IPv6 地址。

扩展将 URL 写入 App Group `group.com.nuanxinban.indo` 的
`pendingPublicTravelLink`，随后使用公开 URL scheme `travelcompanion://import` 打开主 App，
不在 URL query 中传递行程链接。主 App 只从 App Group 读取待处理 URL，并在首个可用旅行日
打开新增卡片编辑器、预填链接。系统若拒绝打开宿主，待处理值会在用户下次进入 App 时消费。

扩展不抓取第三方内容、不使用私有 API，也不处理账号数据。发布前需在 Apple Developer
账户中为两个 bundle identifier 启用相同的 App Group；该配置仅用于本机扩展交接。
