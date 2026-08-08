# Rapid Project Plan

## Request
删除首页真实 MapLibre Pin 上的全部 Gooey 融合/分离视觉效果，恢复 resolver 最终形态的直接更新；完整保留独立 Gooey Pin Demo 页面、入口、自由拖拽、参数面板及测试。

## Decision Gates
- [x] Confirm architecture: 沿用现有本地 SwiftUI + MapLibre 首页与独立 SwiftUI Demo；仅删除首页瞬态 Gooey 表现层，不改变业务 resolver、地图、路线或数据。
- [x] Confirm technology stack: 沿用 Swift/SwiftUI、MapLibre 与现有 Xcode 工程，不新增依赖。

## Project Locations
- Frontend: `/Users/yangzhiyuan/Documents/indo/travel-companion-ios`
- Backend: N/A
- Public hostname: N/A

## Assumptions
- Target platform: 现有 iPhone/iOS 首页地图与 Debug 模拟器。
- Data ownership: Pin 聚合、拆分、位置、成员与选择仍完全由现有 MapLibre resolver 管理。
- Deployment target: 本地源码、测试与 Debug 构建；不提交、不推送、不部署、不上传 TestFlight。
- MVP scope: 删除首页所有 Gooey production overlay、transition resolver/diff、fallback/coalescer、shape/clarity 与相关测试；保留非 Gooey 的 Pin 位置/圆角动画和整个 Demo。
- Deliverables: 代码清理、产品/技术规格回退、首页地图与 Demo 回归测试、Debug 构建、独立规格及质量复核。

## Execution Checklist
- [x] Record assumptions: target platform, data ownership, deployment target, MVP scope, and deliverables.
- [x] Reuse and update the existing complete PRD; do not recreate it.
- [x] Reuse the existing homepage Pin and Demo product feature documents; update only the homepage Gooey boundary.
- [x] Product documents already live under `docs/product/`.
- [x] Confirm architecture and technology stack before writing project files.
- [x] Reuse the recorded local iOS environment audit; no new blocker or external service is involved.
- [x] Reuse the existing project, git repository, and execution log.
- [x] Reuse the existing local Xcode/Simulator environment; server environment is N/A.
- [x] Existing app target was built and launched; backend skeleton checks are N/A.
- [x] Reuse and update the existing technical design files; no new design document is needed.
- [x] User directly authorized the removal; technical summary will be recorded before coding.
- [x] API contract is N/A for this client-only visual removal.
- [x] Icon collection is N/A; no asset changes.
- [x] Existing navigation, persistence, business entry points, and Demo entry are retained.
- [x] Implement and review directly, without subagents, as explicitly requested by the user.
- [x] Verify the Demo entry remains functional and no homepage Gooey entry/state/rendering path remains.
- [x] Run focused homepage map tests, Demo tests, Debug build, simulator launch, diff and project checks; deployment/DNS/publication are N/A.
- [x] Run completion audit; done 6, deferred 0, blocked 0, missing 0.
- [x] Run direct final source/spec/quality review and append final status to the log; no commit, stage, push, deploy, or TestFlight action performed.
