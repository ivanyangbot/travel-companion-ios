# Rapid Project Plan

## Request
按参考长图迭代首页的列表模式：列表页完整复用首页地图模式的日期时间轴；行程标题与日期时间轴持续吸顶；每日标题滚动到时间轴下方后吸附，并在相邻日期标题到达时被替换。

## Decision Gates
- [x] Confirm architecture: 沿用现有单体 iOS 客户端与既有行程数据层；本次仅修改首页展示层。
- [x] Confirm technology stack: 沿用项目现有 Swift / SwiftUI / SwiftData，不引入新依赖。

## Project Locations
- Frontend: `/Users/yangzhiyuan/Documents/indo/travel-companion-ios`
- Backend: `/Users/yangzhiyuan/nuanxinban/backend/biz-platform/travel-companion-api`
- Public hostname: 不涉及

## Assumptions
- Target platform: 现有 iOS App，竖屏手机尺寸优先。
- Data ownership: 行程内容沿用现有归属；图片最终评分与大图决策由后端持有，客户端只读。
- Deployment target: 本次完成本地实现与构建验证，不发布 TestFlight。
- MVP scope: 首页列表模式、复用地图模式时间轴、分层吸顶、卡片拖动/左滑、图片评分驱动的双形态卡片和当前/下一项时间指示条。
- Expected deliverables: SwiftUI 实现、必要的自动化测试、模拟器截图或等价视觉验证、需求与设计记录。
- Interaction detail: 每日标题固定在全局时间轴下方；后一天标题上推并替代前一天标题，向回滚动时行为对称。

## Execution Checklist
- [x] Record assumptions: target platform, data ownership, deployment target, MVP scope, and deliverables.
- [x] Write a complete PRD and create it only by copying `assets/prd-template.md`.
- [x] Clarify product-level features and create feature docs only by copying `assets/product-feature-template.md`.
- [ ] Move PRD and feature docs into `docs/product/` once the project folder exists.
- [x] Confirm architecture and technology stack before writing project files.
- [x] Run `env-auditor` and resolve required blockers.
- [ ] Create project folders, initialize version control, and start the execution log.
- [x] Prepare local/server development environments.
- [ ] Run frontend and backend skeleton smoke checks as applicable.
- [x] Create technical design files only by copying the technical templates.
- [x] Present the technical design summary and get confirmation before coding unless autonomous implementation is already granted.
- [ ] Run `api-contract-agent` before broad full-stack work.
- [ ] Run `icon-asset-agent` once to create `docs/design/ICON_MANIFEST.md`.
- [ ] Build primary navigation, API contracts, persistence, and entry points.
- [ ] Develop features with implementer, spec-reviewer, and quality-reviewer subagents when available.
- [ ] Verify there are no unimplemented entry buttons, mock data, or incomplete features unless explicitly requested.
- [ ] Run integration QA, builds/tests, release checks, deployment, DNS, and publication as applicable.
- [ ] Run completion audit and resolve or explicitly defer every missing item.
- [ ] Run `final-review-agent`, append final status/manual actions to the log, and create intentional commits.
