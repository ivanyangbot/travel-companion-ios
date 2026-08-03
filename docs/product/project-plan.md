# Rapid Project Plan

## Request
开发一个仅承载“一次旅行”的双人协作旅游攻略 App：前端为原生 iOS，后端为 Flask，避免传统账号鉴权。

核心能力：干净行程 UI/UX；机票、酒店、景点/活动卡片及飞猪、小红书等常用旅行 App 的深链接/分享联动；支出统计；可复制证件/订单/会员等常用号码的卡包；经 API 生成并由用户确认导入的 AI 行程；相邻景点距离与时长计算及地图路线查看；双人协作。

明确范围：唯一共享行程，不提供行程列表、多行程、历史行程或账号体系。第三方联动采用公开链接、URL Scheme 或系统分享，不承诺直接下单、抓取受限内容或写入第三方平台。

初始假设（待用户确认）：
- 目标平台：iOS 17+，SwiftUI 原生 App。
- 数据归属：唯一旅行由两位受邀成员共同持有；卡包敏感数据采用端侧安全存储，默认不跨设备同步，除非用户明确选择共享。
- 部署目标：尚未指定；开发阶段使用本机 Flask + SQLite，生产部署待确认。
- MVP：实现完整的单行程、三类卡片、地图距离/路线、支出、卡包、AI 导入和双人协作闭环。
- 预期交付：独立 iOS 与 Flask 工程、PRD/功能及技术设计、测试与本地运行说明；生产部署/TestFlight 不包含在本阶段，除非另行确认。

## Decision Gates
- [x] Confirm architecture: 已确认 iOS 原生客户端 + Flask API + 云端数据库；用户选择 C（完全公开、无访问限制）。共享行程与支出数据的接口将不设置访问边界；卡包保持本机私有。
- [x] Confirm technology stack: confirmed by user. SwiftUI (iOS 17+) + SwiftData local cache + Flask 3 / SQLAlchemy 2 + PostgreSQL + short-polling synchronization + AutoNavi (Amap) map services + server-proxied AI API.

## Project Locations
- Frontend: <TBD after architecture and stack confirmation; suggested /Users/yangzhiyuan/Documents/indo/travel-companion-ios>
- Backend: <TBD after architecture and stack confirmation; suggested /Users/yangzhiyuan/Documents/indo/travel-companion-api>
- Public hostname: <TBD if a public endpoint is needed>

## Execution Checklist
- [ ] Record assumptions: target platform, data ownership, deployment target, MVP scope, and deliverables.
- [ ] Write a complete PRD and create it only by copying `assets/prd-template.md`.
- [ ] Clarify product-level features and create feature docs only by copying `assets/product-feature-template.md`.
- [ ] Move PRD and feature docs into `docs/product/` once the project folder exists.
- [ ] Confirm architecture and technology stack before writing project files.
- [ ] Run `env-auditor` and resolve required blockers.
- [ ] Create project folders, initialize version control, and start the execution log.
- [ ] Prepare local/server development environments.
- [ ] Run frontend and backend skeleton smoke checks as applicable.
- [ ] Create technical design files only by copying the technical templates.
- [ ] Present the technical design summary and get confirmation before coding unless autonomous implementation is already granted.
- [ ] Run `api-contract-agent` before broad full-stack work.
- [ ] Run `icon-asset-agent` once to create `docs/design/ICON_MANIFEST.md`.
- [ ] Build primary navigation, API contracts, persistence, and entry points.
- [ ] Develop features with implementer, spec-reviewer, and quality-reviewer subagents when available.
- [ ] Verify there are no unimplemented entry buttons, mock data, or incomplete features unless explicitly requested.
- [ ] Run integration QA, builds/tests, release checks, deployment, DNS, and publication as applicable.
- [ ] Run completion audit and resolve or explicitly defer every missing item.
- [ ] Run `final-review-agent`, append final status/manual actions to the log, and create intentional commits.

## PRD Draft Status

- PRD drafting delegated to `prd-author`; its full draft will be copied from the bundled template into `docs/product/PRD.md` only after folders are created.
- Product feature clarification identified seven independently testable modules: shared single itinerary; travel cards and external links; maps and routing; spending; secure card wallet; AI itinerary import; two-person collaboration.
- Blocking question recorded below before architecture confirmation: choose the no-login access boundary for the two participants.

## Open Question 1 — Shared Access

Recommended: private invite link or QR code containing an unguessable itinerary access token. Either participant can reset it to revoke the other device. This preserves the requested absence of traditional login while preventing the itinerary, spending data, and card wallet from being exposed to anyone who knows the API address.

| Option | Description |
| --- | --- |
| A | Private invite link / QR access token (recommended) |
| B | A fixed shared passcode entered on both devices |
| C | No access control; any caller can read and write — confirmed by user |

## Architecture Decision

Confirmed architecture: native iOS app + Flask monolithic JSON API + cloud database. The iOS app owns presentation, local cache, local-only card wallet, external app handoff, and offline queue. Flask owns public shared-trip APIs, synchronization, AI requests, and map web-service requests. The server must never receive card-wallet contents.

Known consequence: this is intentionally unsuitable for real sensitive shared data because anyone able to discover the API endpoint/resource identifiers can read or overwrite shared itinerary and spending data. The server will retain only non-sensitive shared trip data; production HTTPS, request limits, CORS restrictions, and input validation remain necessary reliability controls, not access control.

## Stack Decision

Confirmed by user: SwiftUI (iOS 17+) with SwiftData for cache, Flask 3 + SQLAlchemy 2 with PostgreSQL, short polling for collaboration, Amap for China map/routing support, and an AI API accessed only via Flask. Initial project folders will be placed below the current workspace unless the environment checkpoint reveals a configured backend workspace.
