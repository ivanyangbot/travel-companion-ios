# Feature Implementation: 存量 POI 多图回填与算法验证

## Goal
在既有 Flask/PostgreSQL 图片任务架构中，用中国大陆可访问的 Bing 图片搜索替换 Wikimedia/Wikidata，修复小红书搜索，补充 POI 别名、横图封面排序和候选扩量，并重新唤醒历史失败任务。

## Files
- Create: N/A
- Modify:
  - 后端 `app/services/poi_images.py`
  - 后端 `scripts/backfill_poi_image_jobs.py`
  - 后端 `tests/test_poi_images.py`
  - 后端 `tests/test_backfill_poi_image_jobs.py`
  - 后端 `requirements.txt`
  - 后端 `deployment/install-xiaohongshu-mcp.sh`
  - 后端 `deployment/README.md`

## Tasks

### Task 1: 修复候选相关性与查询优先级
- Files: `app/services/poi_images.py`, `requirements.txt`, `tests/test_poi_images.py`
- Implementation: feed 预筛选仅使用实际标题；详情再用标题+正文核验；用 OpenCC 在评分前将繁体统一为简体；查询以精确 place/title 为首项，再使用 destination/address/description/notes 与静态别名表组合并去重。Bing 结果解析 `iusc` 元数据，只下载 `*.mm.bing.net` HTTPS 缓存图并以 `purl` 作为审计来源；运行时不调用 Wikimedia/Wikidata。
- Verification: 单元测试覆盖无关 feed 不被查询词抬分、麗江/丽江和鬆贊/松赞等繁简匹配、三个目标景点的别名、Bing 元数据解析/域名白名单/快速失败和生产主机连通性。

### Task 2: 小红书修复、扩量与逐图视觉裁决
- Files: `app/services/poi_images.py`, `tests/test_poi_images.py`
- Implementation: sidecar 搜索页使用明确的 60 秒页面 deadline，避免 API 请求取消后 Rod `MustWait` 无界挂起；后端搜索超时与 sidecar deadline 对齐。每轮最多读取 6 篇笔记并尝试最多 6 个精确名/区域/别名查询。将初筛后的小红书图片缩略后在单次 OpenAI-compatible vision 请求中批量判定 POI 主体、人物主体、非照片、旅行封面代表性和语义分；请求或响应字段不完整时仅对 XHS 候选 fail closed，不影响 Bing。
- Verification: mock 视觉接口覆盖 POI 主体图通过、自拍/前景摆拍/拼图/无关酒店/截图/普通学校拒绝、城市代表图通过、具体 POI 非代表封面拒绝、字段严格解析、每来源 2 张上限、批量单请求和失败关闭。

### Task 3: 安全可控的存量回填 CLI
- Files: `scripts/backfill_poi_image_jobs.py`, `tests/test_backfill_poi_image_jobs.py`
- Implementation: argparse 支持 `--dry-run`、重复 `--card-id`、`--limit`、`--force-retry`、`--process-now`；输出 JSON 报告；只选无图 activity/hotel，不触及已有图。
- Verification: SQLite 集成测试验证 dry-run 零写入、limit/ID 过滤、唤醒 daily retry 和已有图保护。

### Task 4: 横图封面优先与生产重排
- Files: `app/services/poi_images.py`, `tests/test_poi_images.py`, `scripts/backfill_poi_image_jobs.py`
- Implementation: 多候选最终排序键增加横向封面适配度，在相关性、画质权重之后优先适合 38:21 大卡的横图；部署后用 `--force-retry --process-now` 唤醒旧 `commons_unavailable`/`xhs_vision_rejected` 任务，先核验独克宗古城、纳帕海、松赞林景区，再继续队列。
- Verification: 单测证明同等相关性和画质时横图先于竖图；生产报告对账目标卡片的来源、图片尺寸、`imageScore/showLargeImage` 与任务状态。

## API/Data Changes
- 不新增外部 HTTP API 或 schema migration。
- CLI 仅用现有 `card_image_jobs` 和 `process_card_image_job`；返回机器可读 JSON 摘要。

## Edge Cases
- 指定不存在、非 POI 或已有图 card ID；dry-run 配合 process-now；已有 pending daily retry；并发 scheduler 抢占；部分图或候选不足；Bing 页面结构变化或限流；小红书登录过期/搜索超时。

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
- 2026-08-09 中国大陆图源切换：运行时寻图链路改为 Bing 中国节点 + Bing HTTPS 缓存图，小红书作为补充；不再调用 Wikimedia/Wikidata。真实生产查询对独克宗古城、纳帕海、松赞林景区均选出 4 张 1600×900 图片，最终分数均为 83，人工 contact sheet 确认三组 POI 语义正确。
- 小红书账号当前被平台重定向到 `/website-login/captcha` 二次扫码页。`v2.4.3-indo2` 在 1 秒内识别并返回，使任务安全回退 Bing；旧版本的 60 秒 Rod panic 已消除。恢复 XHS 实际候选仍需账号持有人扫码，这是外部平台人工验证，不影响 Bing 主链路。
- 发布前后端全量 `324 passed`；生产备份位于 `/opt/backups/travel-companion-api/20260809-0940-bing-cutover`，迁移报告 `Applied migrations: none`，API/sidecar 健康且部署哈希一致。88 个无图旧任务已强制重排；`獨克宗古城` 从 2 张旧图、67/false 刷新为 4 张横图、83/true，`納帕海` 从无图刷新为 4 张横图、82/true。
