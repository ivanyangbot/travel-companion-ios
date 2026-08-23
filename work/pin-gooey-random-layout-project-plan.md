# Rapid Project Plan

## Request
将独立 Gooey Demo 的布局面板改为随机生成；用户设置的是舞台上可见 Pin 的数量，一个聚合 Pin 只计一个，与内部数字成员数无关。所有生成 Pin 可自由拖拽并共享 Gooey 图层，同时模拟首页地图平移、缩放、贴边与单直角样式，并让任意单体/聚合 Pin 对保持稳定数字顺序和延迟过渡。

## Decision Gates
- [x] Confirm architecture: 沿用业务隔离的本地 SwiftUI Demo；随机场景只存在于页面内存，不接首页、网络或持久化。
- [x] Confirm technology stack: 沿用现有 Swift/SwiftUI、Canvas 与 XCTest，不新增依赖。

## Project Locations
- Frontend: `/Users/yangzhiyuan/Documents/indo/travel-companion-ios`
- Backend: N/A
- Public hostname: N/A

## Assumptions
- Target platform: 现有 iOS Pin Gooey Demo sheet。
- Data ownership: 可见 Pin 数量、随机文本/样式、各 Pin 坐标和数字成员融合状态仅属于当前 Demo。
- Deployment target: 本地源码与聚焦测试；不提交、不推送、不发布、不上传 TestFlight。
- MVP scope: `2...12` 个可见 Pin、随机生成按钮、随机单体/聚合样式与位置、全部 Pin 自由拖动、地图 pan/zoom、首页同规则贴边/直角、共享 Gooey 图层。
- Expected deliverables: Demo 源码、随机生成器测试、产品/技术规格和项目日志。

## Execution Checklist
- [x] Record assumptions: target platform, data ownership, deployment target, MVP scope, and deliverables.
- [x] Reuse the existing complete PRD; update only the existing Demo feature entry.
- [x] Reuse the existing complete `pin-gooey-demo` product feature document.
- [x] Product documents already exist under `docs/product/`.
- [x] Reuse the confirmed local-only architecture and SwiftUI/XCTest stack.
- [x] Reuse the already verified Xcode/Simulator environment; no external blocker or credential is involved.
- [x] Reuse the existing project, repository, Demo entry and execution log.
- [x] Existing local iOS environment is prepared; server environment is N/A.
- [x] Existing app skeleton and Demo entry already pass focused smoke checks.
- [x] Reuse the existing technical spec and `pin-gooey-demo` feature design.
- [x] The user directly requested implementation; no additional design gate is blocking.
- [x] API contracts are N/A for this local random state.
- [x] No new icon asset is required; use SF Symbols for the regenerate button.
- [x] Preserve existing navigation, local state, Gooey renderer and test target.
- [x] Implement and review directly because the user explicitly prohibited subagents earlier in this task.
- [x] Verify there are no unimplemented entry buttons, mock data, or incomplete features unless explicitly requested.
- [x] Run applicable integration QA and focused build/tests; deployment, DNS and publication are N/A for this local-only Demo change.
- [x] Run completion audit and resolve or explicitly defer every missing item.
- [x] Skip `final-review-agent` and commits because the user explicitly required direct modification without subagents; append direct audit status to the log instead.
- [x] Generalize the number layer to every single/aggregate pair, prioritize the actively dragged Pin, preserve the last interaction target after release, and retarget after separation.
- [x] Cover single-Pin retargeting, active-pair priority, and aggregate-to-aggregate member/separator animation with focused tests.
- [x] Add a default-on manual-control switch; when off, remove direct Pin hit targets and let simulated map pan/zoom drive automatic Gooey fusion and separation without mutating world positions.
- [x] Cover automatic zoom-driven fusion from fixed world coordinates and rerun the focused Demo suite.
