# Rapid Project Plan

## Request
在独立 Gooey Demo 中加入带稳定成员身份的数字聚合/分离演示：支持 `2.3.7.5.4` 的 `4` 从右侧分离为 `2.3.7.5 + 4`，以及 `7.3.8.12` 的 `3` 从左上方分离为 `7.8.12 + 3`。数字顺序由成员相对位置确定，分离/融合过程中剩余成员不得离散跳变。

## Decision Gates
- [x] Confirm architecture: 沿用现有本地、业务隔离的 SwiftUI Demo；数字仅是 Demo 场景状态，不接首页或 MapLibre。
- [x] Confirm technology stack: 沿用 Swift/SwiftUI Canvas 与现有 XCTest，不新增依赖。

## Project Locations
- Frontend: `/Users/yangzhiyuan/Documents/indo/travel-companion-ios`
- Backend: N/A
- Public hostname: N/A

## Assumptions
- Target platform: 现有 iOS Debug Demo sheet。
- Data ownership: 两个静态数字场景及成员相对坐标只存在于 Demo 本地状态，关闭即丢弃。
- Deployment target: 本地源码、测试、Debug 构建与模拟器；不提交、不推送、不部署、不上传 TestFlight。
- MVP scope: 场景切换、空间排序、稳定成员槽位、连续融合/分离数字动画、辅助功能文本及回归测试。
- Deliverables: Demo 源码、测试、产品/技术规格、项目日志和完成审计。

## Execution Checklist
- [x] Record assumptions: target platform, data ownership, deployment target, MVP scope, and deliverables.
- [x] Reuse and update the existing complete PRD rather than recreating it.
- [x] Reuse and update the existing Pin Gooey Demo product feature document.
- [x] Existing product documents already live under `docs/product/`.
- [x] Confirm architecture and technology stack before feature edits.
- [x] Reuse the previously verified local iOS environment; no external blocker is involved.
- [x] Reuse the existing project, repository, Demo entry and execution log.
- [x] Reuse the existing Xcode/Simulator environment; server environment is N/A.
- [x] Existing app skeleton and Demo entry are already runnable; backend smoke checks are N/A.
- [x] Reuse and update the existing technical spec and Demo feature design.
- [x] Present the technical design summary; the user explicitly authorized direct implementation.
- [x] API contracts are N/A for this local-only visual state.
- [x] Icon collection is N/A; no new icon asset is required.
- [x] Preserve the existing navigation and Demo entry; no persistence or API work is required.
- [x] Implement and review directly, without subagents, as explicitly requested by the user.
- [x] Verify there are no unimplemented entry buttons, business mock data, or incomplete Demo paths; both scenarios remain local static presentation data.
- [x] Run applicable integration QA: 39 focused tests and Debug build passed before the final width refinement; release/deployment/DNS/publication are N/A. The user explicitly waived another verification pass afterward.
- [x] Run completion audit: implementation and documents cover the requested number ordering, slot locking and homepage-style adaptive width; final re-verification is user-approved as skipped.
- [x] Respect the explicit no-subagent instruction, append final status/manual actions to the log, and leave the dirty worktree uncommitted because no commit was requested.
