# Feature Implementation: 首页吸边 Pin 动态边界、聚合与 Gooey 过渡

## Goal
让普通与边缘 Pin 的位置、聚合和拆分完全由源 POI、物理屏幕中心、动态安全区和真实渲染外框决定；在不参与 resolver 决策的前提下，根据前后 placement 成员集合变化播放短暂、可逆、完整 360° 的 Gooey 融合/分离过渡。

## Files
- Modify: `Sources/TravelCompanion/Features/Today/MapLibreTodayMap.swift`
- Modify: `Tests/TravelCompanionTests/MapsTests.swift`
- Preserve without Gooey changes: `Sources/TravelCompanion/Features/Today/TodayView.swift`、`TodayMapPoint`、卡片/路线/相机模型和工程配置。

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
- 旧 Cuberto bridge、常驻 display link、blur/private filter 与旧拆分动画继续保持删除状态；新的生产 Gooey 使用独立、短生命周期的确定性矢量过渡，不恢复旧实现。
- 高亮态绘制独立 32pt 类别圆点与数字圆/胶囊，避免长标签放大类别圆点。
- 上左/上右的最外层上角、下左/下右的最外层下角去除圆角。
- 数字和类别背景使用固定四段二次曲线路径；指向角半径在 16pt 与 0 之间以 0.28 秒 ease-in-out 插值，因此出现、消失和中途反向都不会离散闪烁。
- 卡片/覆盖层驱动的安全区变化使用旧/新屏幕中心差做 0.28 秒位移动画；地图手势不做位置缓动，但仍允许形状动画。
- 选择态更新保留现有 annotation view，避免整体收起时因重建视图丢失过渡；减少动态效果开启时直接应用终态。

### Resolver 与过渡检测边界
- `calculatedPinPlacements`、`MapLibreRegularPinGrouping`、`MapLibreProjectedEdgePinGrouping` 和 `MapLibreFinalPinGrouping` 仍是唯一成员/代表/位置真相。Gooey 不修改阈值、碰撞、投影、label、代表 ID、选择态、annotation coordinate 或 `pinPlacements`。
- Coordinator 给每次 placement 应用附带 `MapLibrePinPlacementUpdateReason`：`.initial`、`.dataMutation`、`.selection`、`.viewport`、`.safeArea`、`.autoFocus`。首次应用、POI 新增/删除/重排/坐标 CRUD 和纯 selection 更新直接跳过 transition resolver；其余原因只有 canonical member set partition 变化时才可能生成动画。
- 快照只取 resolver 已有信息，不读取 annotation view 的 presentation frame：
  ```swift
  struct MapLibrePinVisualSnapshot: Equatable {
      let representativeID: UUID
      let orderedMemberIDs: [UUID]
      let numberFrame: CGRect
      let labelText: String
      let isHighlighted: Bool
      let showsCategoryBubble: Bool
      let pointingCorner: MapLibreEdgePinPointingCorner?
  }

  struct MapLibrePinPartitionSnapshot: Equatable {
      let updateGeneration: Int
      let placements: [MapLibrePinVisualSnapshot]
  }
  ```
- 集合比较使用 `Set<UUID>`，动画分支顺序使用 resolver 的 `orderedMemberIDs`。代表 ID、label 或坐标变化但 canonical member set partition 不变时返回空数组；这保证 regular/edge 切换、纯平移、宽度变化和指向角 morph 不误触发 Gooey。
- 纯函数 `MapLibrePinGooeyTransitionResolver.transitions(previous:current:reason:hasPresentedInitialState:)` 先构建旧/新 member-set 的二部相交图，再按连通分量分类：
  - 多个旧 placement 汇入一个新 placement：`.merge(sources:target:)`。
  - 一个旧 placement 分成多个新 placement：`.split(source:targets:)`。
  - 一对一同成员集合：无 transition。
  - 多对多重分区、成员缺失/新增、重复成员或空集合：视为不安全/CRUD 形态，直接终态，不虚构动画。
- N 成员同帧 merge/split 产生一个 component descriptor，而不是 N 个互相竞争的动画。descriptor 的稳定 key 由本 component 全部 UUID 排序后生成，分支再按原有 display order 排序，保证每次运行得到相同 path 与 layer 顺序。

### 纯函数过渡模型与 360° 几何
```swift
enum MapLibrePinGooeyTransitionKind: Equatable {
    case merge
    case split
}

struct MapLibrePinGooeyBranch: Equatable {
    let orderedMemberIDs: [UUID]
    let sourceFrame: CGRect
    let targetFrame: CGRect
}

struct MapLibrePinGooeyTransitionDescriptor: Equatable {
    let key: MapLibrePinGooeyTransitionKey
    let kind: MapLibrePinGooeyTransitionKind
    let branches: [MapLibrePinGooeyBranch]
    let localBounds: CGRect
}

struct MapLibrePinMetaballSample: Equatable {
    let outerPath: CGPath
    let innerPath: CGPath
    let clarityItems: [MapLibrePinClarityItem]
}
```
- `MapLibrePinGooeyGeometry.descriptor(...)` 将所有相关 number frame 的 union 转成 map-local `localBounds`，仅外扩橙色描边、控制点和 2pt safety；再与 map 可见 bounds 相交。每个活跃 component 只创建这个局部尺寸的 overlay layers，不创建全屏离屏位图。
- 每条 branch 用两个 frame 的真实中心向量 `delta`，`atan2(delta.y, delta.x)` 仅用于测试/调试；绘制直接使用归一化向量与垂线，因此水平、垂直、斜向和 359°/0° 没有离散方向分支。中心重合时使用该 component 最近一次有限方向，首次无方向时固定向右。
- `MapLibrePinGooeyGeometry.surfaceGap` 使用圆/水平胶囊的真实最近表面距离。白色 Pin 高度仍为 32pt；胶囊宽度取 snapshot frame，不把 label 文本作为几何输入。
- `maximumBridgeLength = 96pt`（3 倍 Pin 高度）。任一 branch 的 surface gap 超过上限时该 component 不创建 transition，直接保留已经配置好的 resolver 终态，禁止跨屏长尾。
- `MapLibrePinMetaballPath.sample(descriptor:progress:previousDirection:)` 是确定性纯函数。每个 progress：
  1. 计算 source/target 水平胶囊沿中心向量的有限表面锚点与法向。
  2. 用 `smoothstep` 根据 surface gap 与 progress 算 bridge 半宽，并 clamp 到 0...16pt。
  3. 用两条三次 Bézier 连接两侧锚点；控制柄长度 clamp 到 branch gap 的一半，极近、重合和极宽胶囊均不得产生自交或 NaN。
  4. 多分支按稳定顺序加入同一个 non-zero winding compound path；同一 descriptor 的全部采样保持完全一致的 subpath 数、元素类型和元素顺序，保证 Core Animation 能连续插值而不是跳帧。
  5. outer path 使用橙色，inner path 将稳定表面内缩 2pt、bridge 半宽同步缩小，形成白色主体和确定性橙色外沿；不使用 blur、alpha threshold、Core Image 或私有 filter。
- 数字、`+N` 与类别图标不进入 metaball path。`MapLibrePinClarityItem` 用现有 label/font/icon 配置生成独立、未过滤的 `CATextLayer`/图片 layer，位于 outer/inner shape layers 上方；过渡完成后由现有稳态 `MapLibreNumberedAnnotationView` 继续显示，annotation view 的最终内容和辅助功能身份不变。
- selected 类别圆不成为跨 placement bridge 分支。merge 时 clarity layer 将类别图标短暂淡出，split 后仅当 resolver 最终 target 仍 `showsCategoryBubble` 时恢复；最终橙色描边和 pointing-corner 仍由现有 annotation view 决定。
- `MapLibrePinGooeyBranch` 同时保存 source/target `pointingCorner`。四个端点方向的稳定 capsule 子路径在每一个 keyframe 都使用对应的零半径外侧角；bridge 锚点避开该指向角并连接其余表面。merge 与 split 全程不得把既有直角圆化，overlay 清理前后路径拓扑保持一致。

### MapLibre transient overlay
- 首选 `MapLibrePinGooeyOverlayView: UIView` 作为 MapLibre screen-space、`isUserInteractionEnabled = false`、`accessibilityElementsHidden = true` 的临时视觉宿主。它不成为 annotation、不改变 MapLibre hit testing，也不拥有业务成员状态。
- 每个 component 使用一个局部 container layer，内部只有 outer `CAShapeLayer`、inner `CAShapeLayer` 和必要的 clarity layers。overlay 使用最终 annotation view 同一屏幕坐标系；坐标转换只在 descriptor 创建/重定向时完成。
- `CAKeyframeAnimation(keyPath: "path")` 使用固定采样进度（建议 0、0.125、…、1）驱动双 shape layer，时长沿用 0.28 秒 ease-in-out。merge 与 split 使用同一组纯 path samples 的正序/反序，不创建 `CADisplayLink`、Timer 或逐帧 Swift 回调。
- 稳态 annotation views 先被配置为 resolver 最新终态。overlay 在其上绘制临时背景时，同时以 clarity layers 重画相关最终文字/图标，避免 shape layer 覆盖造成模糊；过渡清理后稳态 view 无缝接管。临时层不复制 AX label、不响应触摸。
- 最多同时保留 4 个 component transitions；超限 component 按稳定 key 顺序直接终态。单 component 的 branch 数可为 N，但 local bounds、layer 数和 keyframe 数均有硬上限；无法在预算内生成有效 path 时直接终态。

### Coordinator 接入与生命周期
1. `makeUIView` 为 Coordinator 安装一个 overlay，并订阅 `UIAccessibility.reduceMotionStatusDidChangeNotification`；`dismantleUIView`/Coordinator teardown 移除 observer、动画和 overlay。
2. `updateContent` 在调用 `updatePinPlacements` 时传入明确 reason。`pointsChanged` 一律 `.dataMutation`（包括新增、删除、重排、坐标改变）；`selectionChanged` 一律 `.selection`。viewport、safe area 和 auto-focus 保留各自原因。
3. `calculatedPinPlacements` 及所有 grouping/resolver 代码不改。`applyPinPlacements` 在替换 `pinPlacements` 前后生成纯 visual snapshots，先应用并配置最终 annotation views，再把允许的 member-set diff descriptor 交给 overlay。
4. 活跃 transition 以 descriptor key 存储 generation token。相同终态的新几何从 `CAShapeLayer.presentation()?.path` 重定向到新 keyframes；完全反向的 partition 变化同样从当前 presentation path 反向收敛，不回到旧起点、不排队。
5. 新 descriptor 与活跃 component 不兼容、数据 CRUD、纯 selection、非法 path、超长 bridge、超并发或 Reduce Motion 时，立即 `removeAllAnimations()`、移除 component layers，并保持已经配置好的 resolver 终态。
6. completion 仅在 generation token 仍匹配时清理；完成、取消、反向、map teardown 后都清空 shape/clarity layers、path samples 和 snapshot 引用。无活跃 transition 时 overlay 不保留刷新循环或离屏资源。
7. 连续 pan/zoom 仍每次实时应用最新 placement。Gooey 不等待 `regionDidChange`；如果成员 partition 未变，只更新稳态位置/现有 corner morph，不启动或重启 transition。

### Reduce Motion、失败与性能降级
- `UIAccessibility.isReduceMotionEnabled` 为 true 时 transition resolver 可以照常供测试，但 Coordinator 不创建 overlay layer，直接显示最终 annotation views。运行中开启时同步取消全部 component；关闭后不补播历史变化。
- 任意 center/frame/path 非有限、局部 bounds 为空、branch 超过最大桥长、并发超过 4 或 keyframe 生成超过本帧预算时，该 component 直接终态。降级绝不回写 resolver 或隐藏正确的稳定 Pin。
- 性能目标：至少 30 个可见 Pin、最多 4 个活跃 component 时约 55fps 以上，Gooey 增量主线程 p95 小于 4ms，10 秒 pan/zoom 不出现超过 100ms 的 Gooey 阻塞。path samples 仅在 descriptor 创建/重定向时生成，CA 在渲染线程插值。

### 自动定位去聚合
- `TodayView` 将目标卡片 UUID 与相机坐标一起传给 MapLibre，避免同坐标 POI 无法区分当前目标。
- 默认 13.8 倍定位结束后，从最终 `pinPlacements` 查找包含目标 UUID 的 placement；若成员数大于 1，则保持目标居中并每次增加 1 级缩放，逐次重算真实碰撞结果。
- 目标成为 singleton 后立即清除追焦状态；达到 MapLibre 最大倍率时安全停止，防止完全相同坐标造成无限循环。
- 新相机请求会替换旧追焦；检测到用户手势时立即取消。重复点击已居中的卡片即使 MapLibre 不发送相机结束回调，也会直接检查并启动放大。

## Verification
- 保留 `MapsTests` 既有 40 项结果不变；新增纯函数测试覆盖：首次/CRUD/selection/同成员不触发，regular、edge 与 seam 的 merge/split，二部连通分量与 N 成员稳定排序，代表 ID 改变但成员不变，八个代表角度和 0...359° 有限值，中心重合 fallback，96pt 最大桥长，compound path 有限/非空/无错误方向，多对多直接终态，中途反向 generation、Reduce Motion 和 overlay 清理状态机。
- 聚焦测试：
  ```sh
  xcodebuild -project TravelCompanion.xcodeproj -scheme TravelCompanion \
    -sdk iphonesimulator \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.1' \
    -only-testing:TravelCompanionTests/MapsTests test CODE_SIGNING_ALLOWED=NO
  ```
- Debug build：
  ```sh
  xcodebuild -project TravelCompanion.xcodeproj -scheme TravelCompanion \
    -sdk iphonesimulator \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.1' \
    build CODE_SIGNING_ALLOWED=NO
  ```
- 模拟器人工检查：regular、四边 edge、上左/上右/下左/下右四种指向角和 seam 分别 merge/split；选中类别圆、超宽 `+N`、359°/0°、自动追焦连续拆分、动态卡片边界、快速来回 100 次、中途反向、Reduce Motion 运行中切换。确认文字/图标清晰、地图手势不被拦截，且四种指向直角在 Gooey 全程不消失、不圆化。
- Instruments 或等价采样：30 个可见 Pin、最多 4 组同时 transition，记录帧率、主线程 p95、最长阻塞、活跃 layer/animation 数和 100 次往返后的对象数量；每次完成/取消后 component layer 数回到 0，无 display link、Timer、滤镜和离屏资源增长。
- 文档/差异检查：`git diff --check -- docs/design/TECHNICAL_SPEC.md docs/design/features/home-edge-pin-gooey.md`。
- 不执行后端、部署、提交、推送或 TestFlight 操作。
