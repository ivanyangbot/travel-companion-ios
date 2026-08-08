# Rapid Project Plan

## Request
将现有 Pin Gooey Demo 从四个预设方向、单体 Pin 轴向拖拽升级为完整二维实验台：单体 Pin 与聚合 Pin 均可在舞台内自由拖动，二者任意相对位置形成连续 360° 的融合/分离效果。

## Decision Gates
- [x] Architecture: 继续使用与业务隔离的本地 SwiftUI Demo sheet，不接地图、POI、网络或持久化。
- [x] Technology: 继续使用 SwiftUI Canvas/GraphicsContext filter；将状态改为两个二维中心点和实时向量距离，不新增依赖。

## Project Locations
- Frontend: `/Users/yangzhiyuan/Documents/indo/travel-companion-ios`
- Backend/deployment/public hostname: N/A

## Assumptions
- Target platform: 现有 iPhone/iOS 26 SwiftUI 工程。
- Data ownership: 仅 Demo 页内两个 Pin 的瞬态位置与参数。
- Deployment target: 本地 Debug 构建与模拟器验证；不 commit/push/deploy/TestFlight。
- MVP scope: 两个 Pin 均二维自由拖动；任意角度连续融合；固定等高；聚合宽度和 Gooey 参数继续可调；拖拽边界安全。
- Deliverables: 更新 Demo、几何/手势测试、产品/技术文档、验证与审计日志。

## Execution Checklist
- [x] 记录用户对 360° 和双 Pin 自由拖动的明确澄清。
- [x] 更新产品 Feature 和技术 Feature，移除四方向/单轴假设。
- [x] 运行只读环境检查并确认现有 staged 改动保持不变。
- [x] 将状态模型重构为两个可拖 Pin 的二维中心点。
- [x] 删除方向 segmented control，增加自动角度/真实表面间距读数和位置重置。
- [x] 实现两个独立拖拽命中区、边界 clamping、尺寸变化后的安全位置修正。
- [x] 更新辅助功能动作，使两枚 Pin 都能无直接触控调整位置/融合分离。
- [x] 添加 360°、双拖拽、边界、极端宽度和无 NaN 回归测试。
- [x] 运行 29 项聚焦测试、Debug build、模拟器多角度拖拽与 AX 验证。
- [x] 规格/质量/最终审计 PASS；不执行 commit/push/deploy/TestFlight。
