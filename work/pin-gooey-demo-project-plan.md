# Rapid Project Plan

## Request
参考 Cuberto/gooey-cell 与开源 Swift gooey/metaball 实现，在现有 iOS App 中新增独立的 Pin Gooey 视觉调参 Demo。Demo 不接 POI、地图、数字或其他业务数据，通过拖拽完成单体 Pin 与聚合 Pin 的融合/分离，并可调融合方向、聚合 Pin 宽度及主要 Gooey/吸附参数；两类 Pin 高度固定一致。

## Decision Gates
- [x] Architecture: 沿用现有本地 SwiftUI App，Demo 与 Today/MapLibre 业务隔离，无后端、网络或持久化。
- [x] Technology: Swift 6 + SwiftUI `Canvas`/`GraphicsContext` + `DragGesture`，不新增 CocoaPods、POP 或其他依赖。

## Project Locations
- Frontend: `/Users/yangzhiyuan/Documents/indo/travel-companion-ios`
- Backend/deployment/public hostname: N/A

## Assumptions
- Target platform: 现有 iPhone/iOS 26 工程；`Canvas` 所需 iOS 15+ 已由部署目标覆盖。
- Data ownership: 仅页面内瞬态参数和拖拽状态，不读取或保存用户/旅程数据。
- Deployment target: 仅本地 Debug 构建与模拟器验证，不部署、不提交、不推送、不上传 TestFlight。
- MVP scope: 一枚固定聚合胶囊和一枚可拖拽单体圆 Pin；四方向、固定 32pt 高、宽度和 Gooey/吸附参数可调、可恢复默认。
- Deliverables: 独立 Demo 页面、齿轮入口、纯几何/状态测试、需求/设计/验证记录。

## Execution Checklist
- [x] 盘点首页 Pin 形态、入口、工作树和 Xcode 工程管理方式。
- [x] 研究 Cuberto、SwiftUI Canvas 与矢量 metaball 开源实现及许可证。
- [x] 明确独立 UI-only 架构和现有 SwiftUI 技术栈。
- [x] 运行只读 iOS 环境检查；Git、Xcode、Swift 均通过。
- [x] 从模板创建产品 Feature 与技术 Feature 文档。
- [x] 实现 Canvas Gooey 轮廓、四方向布局、拖拽和吸附滞回。
- [x] 实现参数面板、恢复默认和小屏滚动布局。
- [x] 通过现有禁用的设置齿轮打开 Demo sheet，不改变正式 Tab 选择。
- [x] 添加几何/状态单元测试并手工注册新 source，避免 XcodeGen 降低 build number。
- [x] 运行 12 项聚焦测试、Debug 构建和 iPhone 17 Pro 模拟器视觉/AX 检查。
- [x] 完成规格、质量与 completion audit；未执行 commit/push/deploy/TestFlight。
