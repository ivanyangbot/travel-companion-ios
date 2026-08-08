# Feature Implementation: 存量 POI 多图回填与算法验证

## Goal
在既有 Flask/PostgreSQL 图片任务架构中，修复小红书相关性预筛选和延迟任务无法重新唤醒的问题，提供可预览、可限量、可强制重试和可立即处理的生产 canary/回填命令。

## Files
- Create: N/A
- Modify:
  - 后端 `app/services/poi_images.py`
  - 后端 `scripts/backfill_poi_image_jobs.py`
  - 后端 `tests/test_poi_images.py`
  - 后端 `tests/test_backfill_poi_image_jobs.py`
  - 后端 `requirements.txt`

## Tasks

### Task 1: 修复候选相关性与查询优先级
- Files: `app/services/poi_images.py`, `requirements.txt`, `tests/test_poi_images.py`
- Implementation: feed 预筛选仅使用实际标题；详情再用标题+正文核验；用 OpenCC 在评分前将繁体统一为简体；查询以精确 place/title 为首项，再使用 destination/address/description/notes 组合并去重。Commons 端点首次不可用即停止本轮后续查询。
- Verification: 单元测试覆盖无关 feed 不被查询词抬分、麗江/丽江和鬆贊/松赞等繁简匹配、primary-first 查询、多字段查询和 Commons 单次快速失败。

### Task 2: 小红书候选逐图视觉裁决
- Files: `app/services/poi_images.py`, `tests/test_poi_images.py`
- Implementation: 将初筛后的小红书图片缩略后在单次 OpenAI-compatible vision 请求中批量判定 POI 主体、人物主体、非照片、旅行封面代表性和语义得分。`representativeScene` 对所有 XHS 图片都是强制门槛；城市/区域仅允许主要地标、全景/天际线、特色历史街区或代表性自然景观，普通学校/办公室/店面/住宅/停车场/普通道路必须拒绝。前景/中央摆拍即按人物主体拒绝，拼图/多宫格按非照片拒绝；每笔记最多选 2 张。复用现有 `AI_API_BASE_URL/AI_API_KEY/AI_VISION_MODEL`；请求或响应字段不完整时仅对 XHS 候选 fail closed，不影响 Wikidata/Commons。
- Verification: mock 视觉接口覆盖 POI 主体图通过、自拍/前景摆拍/拼图/无关酒店/截图/普通学校拒绝、城市代表图通过、具体 POI 非代表封面拒绝、字段严格解析、每来源 2 张上限、批量单请求和失败关闭。

### Task 3: 安全可控的存量回填 CLI
- Files: `scripts/backfill_poi_image_jobs.py`, `tests/test_backfill_poi_image_jobs.py`
- Implementation: argparse 支持 `--dry-run`、重复 `--card-id`、`--limit`、`--force-retry`、`--process-now`；输出 JSON 报告；只选无图 activity/hotel，不触及已有图。
- Verification: SQLite 集成测试验证 dry-run 零写入、limit/ID 过滤、唤醒 daily retry 和已有图保护。

## API/Data Changes
- 不新增外部 HTTP API 或 schema migration。
- CLI 仅用现有 `card_image_jobs` 和 `process_card_image_job`；返回机器可读 JSON 摘要。

## Edge Cases
- 指定不存在、非 POI 或已有图 card ID；dry-run 配合 process-now；已有 pending daily retry；并发 scheduler 抢占；部分图或候选不足；Commons 在大陆主机超时。

## Human Verification
- 生产备份后运行 10 个分层 canary，检查图片文件可读、尺寸、来源、POI 匹配和已有图零覆盖。
- 任一跨城市/错 POI 封面触发停止扩批。

## Done Criteria
- 聚焦测试和后端全量 pytest 通过。
- 部署文件白名单 SHA-256 一致，服务健康和日志无 traceback。
- canary 报告可对账，已有图覆盖数为 0，再决定扩批。

## Production Verification
- 最终本地结果：49 个聚焦测试、317 个后端全量测试通过；规格与质量复审均 PASS。
- 生产使用三份完整 PostgreSQL/代码快照迭代，最终算法文件 SHA-256 为 `c69eb654f15b21ba57830ebdc4c249df9331b2566f9fd9b2d8fcbddaf0ab4ed5`，服务 health 正常且发布后无 warning/error 日志。
- 10 卡 canary 和历史成功卡复核促成两次现场改进：拒绝摆拍/拼图，以及所有 XHS 图片强制 `representativeScene=true`；普通学校和无法定位的通用海滩已清理。
- 交接时 94 张 POI 中 6 张保留 10 张最终规则通过的有效 JPEG；其余 88 张已进入持久任务，2 张运行、64 张等待首次领取，失败项推迟到次日重试以避免抢占首轮。
