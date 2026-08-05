# Rapid Project Plan

## Request
部署已完成本地实现和验证的 POI 自动补图后端：同步 Flask 代码，安装固定版本 Pillow，执行 0011_card_image_jobs 生产迁移，重启服务并完成健康与功能验收。

## Decision Gates
- [x] Confirm architecture: 沿用已确认的 SwiftUI 客户端 + Flask/Gunicorn + PostgreSQL + Nginx 架构；本轮不改变客户端或公网拓扑。
- [x] Confirm technology stack: 沿用 Python 3/Flask/SQLAlchemy/Pillow、systemd Gunicorn 和现有 indo.nuanxinban.com 生产部署。

## Project Locations
- Frontend: /Users/yangzhiyuan/Documents/indo/travel-companion-ios（仅记录发布日志，不发布新客户端）
- Backend: /Users/yangzhiyuan/nuanxinban/backend/biz-platform/travel-companion-api
- Public hostname: indo.nuanxinban.com

## Execution Checklist
- [x] Record assumptions: iOS 首页继续读取 card.images.first；生产数据库与用户行程保持原所有权；目标为现有 Flask 服务；范围仅含补图任务、Pillow 与 0011 迁移；交付为健康的生产服务和验证记录。
- [ ] Write a complete PRD and create it only by copying `assets/prd-template.md`.
- [ ] Clarify product-level features and create feature docs only by copying `assets/product-feature-template.md`.
- [ ] Move PRD and feature docs into `docs/product/` once the project folder exists.
- [x] Confirm architecture and technology stack before writing project files.
- [x] Run `env-auditor` and resolve required blockers.
- [ ] Create project folders, initialize version control, and start the execution log.
- [x] Prepare local/server development environments.
- [x] Run frontend and backend skeleton smoke checks as applicable.
- [ ] Create technical design files only by copying the technical templates.
- [ ] Present the technical design summary and get confirmation before coding unless autonomous implementation is already granted.
- [ ] Run `api-contract-agent` before broad full-stack work.
- [ ] Run `icon-asset-agent` once to create `docs/design/ICON_MANIFEST.md`.
- [x] Build primary navigation, API contracts, persistence, and entry points.
- [x] Develop features with implementer, spec-reviewer, and quality-reviewer subagents when available.
- [ ] Verify there are no unimplemented entry buttons, mock data, or incomplete features unless explicitly requested.
- [x] Run integration QA, builds/tests, release checks, deployment, DNS, and publication as applicable.
- [x] Run completion audit and resolve or explicitly defer every missing item.
- [x] Run `final-review-agent` and append final status/manual actions to the log; intentionally skip commits because deployment did not authorize committing unrelated dirty worktrees.

## Release Outcome
- Production backup: `/opt/travel-companion-api/.deploy-backups/20260805T111133Z-poi-images`
- Dependency: Pillow 11.3.0 installed in the production virtual environment; `pip check` passed.
- Database: `0011_card_image_jobs` applied; 13 columns and `ix_card_image_jobs_status_next` verified.
- Runtime: `travel-companion-api.service` is active and enabled; three consecutive local health checks returned database/service status `ok`; post-start logs contained no scheduler traceback or worker boot failure.
- Feature readiness: ARK provider configuration is present and POI image background processing defaults to enabled.
- Independent final review: PASS; all 9 deployed file SHA-256 values match local sources and no missing/invalid items were found.

## Explicit Deferrals
- PRD, feature docs, technical templates, API-contract/icon agents, new project scaffolding, DNS changes, and client publication are not applicable to this incremental backend-only production release.
- No commit was created because the user requested deployment only and the working trees contain unrelated user changes.
