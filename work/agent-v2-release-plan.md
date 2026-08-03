# Rapid Project Plan

## Request
Build the existing SwiftUI iOS client and deploy the existing Flask Agent v2
backend.  This is a release verification pass for the approved Agent v2 work,
not a new product scope.

## Decision Gates
- [x] Confirm architecture: existing local-first SwiftUI client plus Flask API;
  the user has already approved this architecture and deployment target.
- [x] Confirm technology stack: SwiftUI/Xcode simulator build and Flask/Gunicorn
  deployment; no TestFlight upload or source-control push is in scope.

## Project Locations
- Frontend: /Users/yangzhiyuan/Documents/indo/travel-companion-ios
- Backend: /Users/yangzhiyuan/nuanxinban/backend/biz-platform/travel-companion-api
- Public hostname: indo.nuanxinban.com

## Execution Checklist
- [x] Record assumptions: iOS remains local-first; confirmed drafts remain local;
  production target is the existing Gunicorn service on indo.nuanxinban.com;
  deliverables are a successful simulator build and deployed backend health plus
  Agent stream verification. No TestFlight, commit, or push.
- [ ] Write a complete PRD and create it only by copying `assets/prd-template.md`.
- [ ] Clarify product-level features and create feature docs only by copying `assets/product-feature-template.md`.
- [ ] Move PRD and feature docs into `docs/product/` once the project folder exists.
- [ ] Confirm architecture and technology stack before writing project files.
- [x] Run `env-auditor` and resolve required blockers.
- [ ] Create project folders, initialize version control, and start the execution log.
- [x] Prepare local/server development environments.
- [x] Run frontend and backend smoke checks as applicable.
- [ ] Create technical design files only by copying the technical templates.
- [ ] Present the technical design summary and get confirmation before coding unless autonomous implementation is already granted.
- [ ] Run `api-contract-agent` before broad full-stack work.
- [ ] Run `icon-asset-agent` once to create `docs/design/ICON_MANIFEST.md`.
- [ ] Build primary navigation, API contracts, persistence, and entry points.
- [ ] Develop features with implementer, spec-reviewer, and quality-reviewer subagents when available.
- [ ] Verify there are no unimplemented entry buttons, mock data, or incomplete features unless explicitly requested.
- [x] Run integration QA, builds/tests, release checks, and backend deployment.
- [x] Run completion audit and explicitly defer product work outside this
  release request (full PRD completion and LinkReader integration).
- [x] Run `final-review-agent`, append final status/manual actions to the log. No
  commit is requested.
