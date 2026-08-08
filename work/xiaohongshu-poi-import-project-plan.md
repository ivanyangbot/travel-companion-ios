# Rapid Project Plan

## Request
在现有 TravelCompanion 后端接入开源小红书内容解析能力：用户可在现有 Agent 页面粘贴分享文本/链接，或要求 Agent 联网搜索相关小红书内容；Agent 解析真实链接中的公开笔记内容，抽取一个或多个 POI 行程卡片候选，并继续经过既有 Apple Maps POI 验证和用户确认后写入行程。增加离线夹具、单元测试和 Agent 工具编排测试。仅修改本地代码和文档，不部署、不写生产数据、不提交或推送。

## Decision Gates
- [x] Confirm architecture: 沿用已确认的 SwiftUI Agent 页面 + Flask Agent v2 + 服务端 AI/Apple Maps 组合；新增小红书公开内容解析器和 Agent 函数工具，不新建独立页面或服务。
- [x] Confirm technology stack: 沿用 Swift 6/iOS 26 客户端与 Python 3.9+、Flask 3.1、pytest 后端；解析器优先使用 Python 标准库和现有依赖，不引入浏览器运行时。

## Project Locations
- Frontend: /Users/yangzhiyuan/Documents/indo/travel-companion-ios
- Backend: /Users/yangzhiyuan/nuanxinban/backend/biz-platform/travel-companion-api
- Public hostname: indo.nuanxinban.com（本次不部署、不修改线上配置）

## Assumptions
- Target platform: 现有 iOS Agent 工作台；输入仍走自然语言消息框，候选仍走现有卡片确认 UI。
- Data ownership: 仅读取用户提供或 AI 搜索发现的公开小红书页面；不使用第三方账户 Cookie，不绕过验证码，不持久化原始笔记正文。
- Deployment target: 仅本地实现与验证；生产部署需要用户另行明确授权。
- MVP scope: 分享文本/长短链解析、SSR/OG 内容提取、Agent 小红书读取工具、联网搜索后工具调用、POI 候选进入既有地图验证链路、失败可理解地反馈。
- Expected deliverables: 解析器、Agent 工具契约与编排、回归测试夹具、产品/技术文档和本地测试结果。

## Execution Checklist
- [x] Record assumptions: target platform, data ownership, deployment target, MVP scope, and deliverables.
- [x] Preserve the existing complete PRD and add the scoped product specification from a copy of `assets/product-feature-template.md`.
- [x] Clarify product-level features and create feature docs only by copying `assets/product-feature-template.md`.
- [x] Move the feature document into `docs/product/features/`.
- [x] Confirm architecture and technology stack before writing project files.
- [x] Run `env-auditor` and resolve required blockers.（无 missing/invalid 项）
- [x] Create project folders, initialize version control, and start the execution log.（复用现有工程与日志）
- [x] Prepare local development environments; no server/deployment environment changes were authorized.
- [x] Run frontend and backend skeleton smoke checks as applicable.（后端 95 项基线通过；iOS 74 项中仅既有模拟器 Keychain -34018 失败）
- [x] Create the feature technical design only by copying `assets/technical-feature-template.md`.
- [x] Present the technical design summary; the user granted autonomous implementation in the request.
- [x] Review the API/tool contract before full-stack work.（由 feature-architect 覆盖；无独立 api-contract-agent 可用）
- [x] Run `icon-asset-agent` once to create `docs/design/ICON_MANIFEST.md`.（现有 Agent 页面无新增图标需求，复用已完成清单）
- [x] Build the Agent tool contract, source binding, share handoff, and existing-page entry points.
- [ ] Develop features with implementer, spec-reviewer, and quality-reviewer subagents when available.
- [ ] Verify there are no unimplemented entry buttons, mock data, or incomplete features unless explicitly requested.
- [ ] Run integration QA and backend tests；部署、DNS、发布均明确不在本次范围。
- [ ] Run completion audit and resolve or explicitly defer every missing item.
- [ ] Run `final-review-agent`, append final status/manual actions to the log, and create intentional commits.
