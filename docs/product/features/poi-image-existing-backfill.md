# Product Feature: 存量 POI 多图回填与算法验证

## Description
对生产数据库中已有、仍无图片的 activity/hotel POI 卡片进行可审计的多图回填。先用只读预览和分层 canary 验证查询、相关性与图片质量，再分批扩大；宁可保留空图，不覆盖用户已有图片或降低质量门槛。

## Inputs
- 生产 POI 的 kind、title、place name/address、description、notes、destination 和已有图片字段。
- 运维参数：dry-run、card-id、limit、force-retry、process-now。

## Outputs
- 指定卡片或限量集合的可对账任务报告。
- 通过本地相关性、画质与近重复检查的最多 4 张服务端图片路径。

## Boundary
### Included
- 只处理 activity/hotel，且不覆盖任何已有图片的卡片。
- 支持只读 dry-run、明确 card ID、limit、强制唤醒延迟重试与立即处理。
- 小红书仅用于当前授权的私人非商业行程；保留第一张审计来源，不宣称获得公开再利用许可。

### Excluded
- 本轮不覆盖或替换用户已有图片。
- 本轮不新增数据库表、不修改 iOS UI、不公开 sidecar 端口。
- 本轮不把“不商用”解释为图片授权，不将来源不明的图片标记为可再分发素材。

## Acceptance Criteria
- dry-run 不修改数据库。
- card-id/limit 只影响选中的无图 POI，已有图卡片修改数为 0。
- force-retry 可唤醒已进入每日重试的 pending 任务；process-now 返回每张卡的处理结果。
- 小红书 feed 预筛选只基于实际标题，不得把查询词注入候选文本人为抬分。
- 小红书候选必须通过逐图视觉语义裁决：POI 主体匹配、人物不占主体、不是地图/截图/海报，并且适合作为当前目标的旅行卡封面；视觉服务不可用或输出字段不完整时对小红书候选关闭失败，不放宽通过。
- 繁体/简体 POI 名称在相关性比较前使用 OpenCC 统一；精确 place name 是第一搜索词。
- 同一小红书笔记最多入选 2 张；前景/中央摆拍人物和拼图/多宫格不得作为 POI 图。
- 城市/区域卡只接受可辨识的主要地标、全景/天际线、特色历史街区或代表性自然景观；普通学校、办公楼、店面、住宅、停车场和普通道路即使招牌含城市名也必须拒绝。
- 回填后图片路径可访问、为有效 JPEG，坏图率为 0；抽样封面 POI 匹配率目标≥95%。
- 执行前保留 PostgreSQL 备份和图片字段快照；明显跨城市误配时停止扩批。

## Data And Permissions
- Data touched: `card_image_jobs`、空图卡片的 `images/image_url/updated_at`、所属行程版本和卡片上传目录。
- Owner: 原行程/卡片所有者；本次操作由项目管理者明确授权。
- Permission/auth expectations: 仅通过生产主机内的应用账号和 loopback sidecar，不输出数据库凭据或 Cookie。

## UX Notes
- Screens/pages: N/A（后端运维任务）。
- Empty/loading/error states: CLI 报告 eligible/queued/reset/processed/succeeded/failed；失败保留 pending 和 error_code。
- Human verification: canary 下载成果抽查 POI 语义、多样性、坐标/城市一致性和已有图零覆盖。

## Open Questions
- 逐图 provenance 表和逐图视觉语义审核留作后续数据模型升级；本轮通过严格笔记文本门槛、每来源限额和人工 canary 控制风险。
