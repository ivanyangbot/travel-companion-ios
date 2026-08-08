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
- [x] Write the scoped product requirements in the copied feature template; a separate greenfield PRD is N/A for this existing backend operation.
- [x] Clarify product-level behavior in `docs/product/features/poi-image-existing-backfill.md`.
- [x] Keep the product feature document under `docs/product/features/`.
- [x] Confirm architecture and technology stack before writing project files.
- [x] Run environment audit and resolve the OpenCC production dependency before restart.
- [x] Reuse the existing repositories and append to `.codex/rapid-project-dev.log`; no new repository was needed.
- [x] Verify local venv, production SSH, PostgreSQL, sidecar login/search, and service health.
- [x] Run backend import and test-suite smoke checks; frontend is N/A.
- [x] Create `docs/design/features/poi-image-existing-backfill.md` from the technical feature template.
- [x] Record the technical design; the user granted autonomous implementation and deployment.
- [x] API contract and icon agents are N/A because no external HTTP API or UI/icon changed.
- [x] Preserve the existing scheduler, persistence model, and Flask entry points.
- [x] Complete implementer, specification-reviewer, and quality-reviewer cycles; final reviews PASS.
- [x] Verify no UI entry points or mock data are introduced.
- [x] Run 49 focused tests, 317 full backend tests, production backups, staged deployment, health checks, canary, and live-model checks.
- [x] Start the durable first production pass and audit every success produced before handoff; 64 unclaimed cards remain and continue automatically under the production scheduler.
- [x] Run the final release audit, append the asynchronous handoff, and explicitly record that no commit was made in the dirty worktrees.

## Production Outcome
- 94 activity/hotel POIs audited; no pre-existing user image was overwritten.
- Final-rule audit retains 6 cards and 10 valid referenced JPEGs; all were visually reviewed, and invalid/missing file count is 0.
- The full no-image queue is active under the deployed scheduler. At handoff: 2 running, 64 awaiting first claim, 24 already attempted or explicitly deferred for retry.
- Strict accuracy is intentional: Commons/Wikidata remain unreachable from the production host, and XHS candidates that are generic, non-representative, people-led, collage-like, or uncertain stay empty.
- No commit or push was created because both repositories already contain unrelated user changes.
