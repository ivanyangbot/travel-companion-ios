# Feature Implementation: 首页吸边 Pin 动态边界与端点槽位

## Goal
让普通与边缘 Pin 的位置、聚合和拆分完全由源 POI、物理屏幕中心、动态安全区和真实渲染外框决定；不使用 gooey 动画桥或沿边挤位。

## Files
- `Sources/TravelCompanion/Features/Today/TodayView.swift`
- `Sources/TravelCompanion/Features/Today/MapLibreTodayMap.swift`
- `Tests/TravelCompanionTests/MapsTests.swift`

## Implementation

### 动态安全区
- `safeOuterRect` 使用左右 20、上 160。
- `TodayView` 在覆盖层显示时传递时间轴实时全局 `minY`；卡片高度动画会持续更新该 preference。
- 整体收起时传 `nil`，MapLibre 使用浮动 Tab Bar 上边缘（屏幕底部上移 92pt）再减 20pt。
- 完整渲染外框越界即触发吸边，而不是等待 POI 或 Pin 越出屏幕。

### 聚合与拆分
- 普通 Pin 先按实际外框重叠做传递闭包，并对加宽后的数字胶囊再次检查碰撞。
- 边缘候选以物理屏幕中心计算方向角，保留 24°/30° 与 42pt/56pt 合并/拆分滞回。
- 左右边使用射线和尺寸修正后的中心矩形交点；若屏幕中心在矩形外，穿越射线选择远侧交点，无交点时使用方向边 fallback。
- 上下边将连续交点量化为左、右端点；同槽外框必然碰撞并聚合，跨屏幕中心直接换槽。
- threshold 拆分只是候选；最终矩形有重叠就重新合并，regular/edge 交界也迭代到固定点。
- 超宽标签使用可容纳的前缀加 `+N`，placement 仍保存全部成员 ID。
- 可用高度不足 66pt 时，高亮边缘代理暂时按 32pt 数字 Pin 投影，避免动态遮挡过程过滤成员。

### 渲染
- 删除 Cuberto/gooey bridge、display link、拆分动画和 metaball path。
- 高亮态绘制独立 32pt 类别圆点与数字圆/胶囊，避免长标签放大类别圆点。
- 上左/上右的最外层上角、下左/下右的最外层下角去除圆角。
- 数字和类别背景使用固定四段二次曲线路径；指向角半径在 16pt 与 0 之间以 0.28 秒 ease-in-out 插值，因此出现、消失和中途反向都不会离散闪烁。
- 卡片/覆盖层驱动的安全区变化使用旧/新屏幕中心差做 0.28 秒位移动画；地图手势不做位置缓动，但仍允许形状动画。
- 选择态更新保留现有 annotation view，避免整体收起时因重建视图丢失过渡；减少动态效果开启时直接应用终态。

### 自动定位去聚合
- `TodayView` 将目标卡片 UUID 与相机坐标一起传给 MapLibre，避免同坐标 POI 无法区分当前目标。
- 默认 13.8 倍定位结束后，从最终 `pinPlacements` 查找包含目标 UUID 的 placement；若成员数大于 1，则保持目标居中并每次增加 1 级缩放，逐次重算真实碰撞结果。
- 目标成为 singleton 后立即清除追焦状态；达到 MapLibre 最大倍率时安全停止，防止完全相同坐标造成无限循环。
- 新相机请求会替换旧追焦；检测到用户手势时立即取消。重复点击已居中的卡片即使 MapLibre 不发送相机结束回调，也会直接检查并启动放大。

## Verification
- `MapsTests` 40/40，覆盖动态边界、位移起点、圆角/直角半径映射、自动追焦倍率策略、上下双槽跳转、四角映射、屏内/边缘/交界碰撞、成员守恒、超宽标签、origin-outside、高亮真实尺寸与窄高度降级。
- Debug 模拟器构建和 iPhone 17 Pro 交互检查。
- 不执行后端、部署、提交、推送或 TestFlight 操作。
