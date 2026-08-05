# Rapid Project Plan

## Request
对生产数据库中已有、尚无图片的 POI 卡片进行一次存量回填：创建持久化图片任务，由现有后台 AI 图片服务自动搜索、筛选并写回。

## Decision Gates
- [x] Confirm architecture: 沿用已部署的 SwiftUI + Flask/Gunicorn + PostgreSQL 架构，本次只做生产数据回填。
- [x] Confirm technology stack: 沿用现有 `card_image_jobs`、ARK AI、Wikimedia Commons 与后台调度器。

## Project Locations
- Frontend: /Users/yangzhiyuan/Documents/indo/travel-companion-ios（仅记录操作日志）
- Backend: /Users/yangzhiyuan/nuanxinban/backend/biz-platform/travel-companion-api
- Public hostname: indo.nuanxinban.com

## Execution Checklist
- [x] Record assumptions: 数据归现有用户/行程所有；仅处理 `activity`/`hotel` 且 `images`、`image_url` 均为空的卡片；不覆盖已有图片；目标为现有生产 PostgreSQL；交付为幂等任务回填、首轮运行观察和健康验证。
- [ ] Write a complete PRD and create it only by copying `assets/prd-template.md`.
- [ ] Clarify product-level features and create feature docs only by copying `assets/product-feature-template.md`.
- [ ] Move PRD and feature docs into `docs/product/` once the project folder exists.
- [x] Confirm architecture and technology stack before writing project files.
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
