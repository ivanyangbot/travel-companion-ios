# Rapid Project Plan

## Request
将已经验证的双 Pin 360° Gooey 融合/分离效果应用到首页真实 Pin，在保留现有地图、聚合、吸边、选中和业务数据行为的前提下，让相邻/聚合变化中的 Pin 产生连续液态连接和断开。

## Decision Gates
- [x] Confirm architecture: 沿用现有本地 SwiftUI + MapLibre 首页架构；仅修改客户端 Pin 表现层，不增加后端、网络接口或持久化。
- [x] Confirm technology stack: 沿用 Swift/SwiftUI、MapLibre annotation 与原生 Core Animation/GraphicsContext 能力，不新增第三方依赖。

## Project Locations
- Frontend: `/Users/yangzhiyuan/Documents/indo/travel-companion-ios`
- Backend: N/A
- Public hostname: N/A

## Assumptions
- Target platform: 现有 iPhone/iOS 26 首页地图。
- Data ownership: 继续由现有 Today/MapLibre 注解与业务模型拥有；Gooey 层只消费渲染 frame 和状态。
- Deployment target: 本地 Debug/Simulator；不提交、不推送、不部署、不上传 TestFlight。
- MVP scope: 首页实际 Pin 在融合与分离过渡中显示 Gooey 连接；不改变聚合成员、吸边位置、点击选择或相机行为。
- Deliverables: 产品/技术文档、首页渲染实现、几何/状态回归测试、模拟器验收和独立审查。

## Execution Checklist
- [x] Record assumptions: target platform, data ownership, deployment target, MVP scope, and deliverables.
- [x] Reuse and update the existing complete `docs/product/PRD.md`.
- [x] Update the existing home Pin product feature with production Gooey acceptance criteria.
- [x] Product documents already live under `docs/product/`.
- [x] Confirm architecture and technology stack before writing project files.
- [x] Run `env-auditor` and resolve required blockers.
- [x] Reuse the existing project, git repository, and execution log.
- [x] Prepare local development environment; server environment is N/A for this client-only change.
- [x] Run the existing iOS project smoke checks; backend skeleton is N/A.
- [x] Update the existing home Pin technical design and implementation order.
- [x] Present the technical design summary; autonomous implementation was granted by the user's direct change request.
- [x] API contract not applicable: client-only visual change.
- [x] Icon collection not applicable: no new icons.
- [x] Existing homepage, data contracts, persistence, and entry points are retained.
- [x] Develop features with implementer, spec-reviewer, and quality-reviewer subagents when available.
- [x] Verify there are no unimplemented entry buttons, mock data, or incomplete features unless explicitly requested.
- [x] Run focused map tests, Debug build, Simulator launch QA, and diff/project checks; rapid-pinch timing is covered by production-overlay regressions and remains available for subjective Simulator feel-check; deployment/DNS/publication are N/A.
- [x] Run completion audit and resolve or explicitly defer every missing item.
- [x] Run independent final specification and quality reviews, append final status/manual actions to the log; do not commit unless separately requested.
