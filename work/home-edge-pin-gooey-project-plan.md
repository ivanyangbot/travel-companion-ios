# Rapid Project Plan

## Request
迭代 iOS 首页地图吸边 Pin：完整外框左/右距屏幕 20pt、上距屏幕 160pt；底边在 POI 覆盖层显示时距时间轴上边缘 20pt，覆盖层整体收起时距底部 Tab Bar 上边缘 20pt。屏内/边缘 Pin 发生视觉重叠时必须合并；方向差达到拆分阈值且最终外框不重叠时才拆分。取消 gooey 效果。上/下边缘只使用左、右两个端点槽位，并以一个直角表示指向；安全区变化产生的位置移动以及圆角/直角切换均需动画。

## Decision Gates
- [x] Architecture: 沿用 SwiftUI `TodayView` + MapLibre `UIViewRepresentable`，只改端侧 UI/布局。
- [x] Technology: 沿用 iOS、Swift、UIKit/Core Animation 与 MapLibre，不新增依赖。

## Project Locations
- Frontend: `/Users/yangzhiyuan/Documents/indo/travel-companion-ios`
- Backend/deployment: N/A

## Assumptions
- 不修改 POI、路线、相机、持久化或后端数据。
- 以物理屏幕中心判断方向；左右边使用真实射线落点，上下边按屏幕中心左右侧跳到端点。
- 不沿边挤开 Pin；任何最终外框碰撞都通过聚合解决。
- 本轮不提交、不推送、不部署、不上传 TestFlight。

## Execution Checklist
- [x] 盘点现有架构、工作树和工具链，保留用户已有改动。
- [x] 实现动态安全边界与覆盖层/Tab Bar 切换。
- [x] 实现普通 Pin、边缘 Pin 和交界处的碰撞闭包。
- [x] 实现方向阈值拆分、上下双端点槽位和四个指向直角。
- [x] 移除 gooey/metaball 绘制与沿边挤位。
- [x] 修复高亮单 Pin 尺寸、超宽聚合标签成员守恒、屏幕中心在安全区外的投影。
- [x] 动态安全区不足 66pt 时将高亮边缘代理降级为 32pt，避免成员消失。
- [x] 卡片/覆盖层改变安全区时以 0.28 秒动画移动 Pin；地图手势位置保持跟手。
- [x] 圆形 Pin 进出上下吸边状态时，以等拓扑路径动画切换圆角/直角，包括地图拖动路径。
- [x] Swiper 切换、卡片点击等自动定位后，若当前 POI 仍在聚合 Pin 中则逐级放大到独立或地图最大倍率。
- [x] 运行聚焦测试与模拟器构建/视觉检查。
- [x] 完成最终规格与质量复审并记录结果；两轮均 PASS。
- [x] 未执行 commit、push、deploy 或 TestFlight。
