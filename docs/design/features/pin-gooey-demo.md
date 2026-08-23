# Feature Implementation: Pin Gooey 360° 双拖拽 Demo

## Goal
交付一个与业务隔离的 SwiftUI 二维实验台：可设置 `2...12` 个可见 Pin，一个聚合 Pin 只计一个；所有 Pin 均可自由拖动并进入同一 Canvas Gooey 图层。舞台模拟地图平移、缩放和首页贴边投影；任意单体/聚合 Pin 对均使用稳定成员的融合分离动画，所有聚合宽度复用首页文字测量规则自动伸缩。

该 Demo 是 App 内唯一 Gooey 渲染入口；不得接入首页 MapLibre placement、resolver、annotation、POI、选择、相机或地图事件。

## Files
- Modify: `Sources/TravelCompanion/Features/Today/GooeyPinDemoView.swift`
- Modify: `Tests/TravelCompanionTests/GooeyPinDemoTests.swift`
- Modify: `docs/product/PRD.md`, `docs/design/TECHNICAL_SPEC.md`, `.codex/rapid-project-dev.log`
- Preserve: `Sources/TravelCompanion/ContentView.swift`, `TravelCompanion.xcodeproj/project.pbxproj` 的既有 Demo 入口和工程注册。

## Tasks

### Task 1: 二维状态和真实胶囊距离
- Files: `GooeyPinDemoView.swift`, `GooeyPinDemoTests.swift`
- Implementation: 用两个有限、0...1 clamped 的归一化中心点替换 `direction + gap`；按各自尺寸和滤镜 padding 映射到合法中心区域。角度由中心向量 `atan2` 推导并归一到 0..<360；融合判定使用单体圆心到水平胶囊中心线段的距离减去两个 16pt 半径。
- Verification: 测试 0°、45°、90°、135°、180°、225°、270°、315°，以及 0...359° 的有限值、中心重合 fallback、端部/长边/斜向 signed surface gap。

### Task 2: 两个独立二维拖拽目标
- Files: `GooeyPinDemoView.swift`, `GooeyPinDemoTests.swift`
- Implementation: 为 aggregate/single 建立各自命中区和 DragGesture；手势开始时记录 Pin 的物理圆心，后续始终以该固定圆心加二维 translation 计算，并针对自适应宽度后的中心边界迭代反算归一化位置。活动 Pin 跳过布局边界补偿，避免宽度变化与拖拽互相抵消；只移动当前 Pin，另一个不动，松手保留落点。
- Verification: 纯函数测试分别移动两 Pin 的 x/y、边角 clamping、极端宽度和 tiny stage；模拟器验证水平、垂直、斜向和完整绕行。

### Task 3: UI、辅助功能和调参迁移
- Files: `GooeyPinDemoView.swift`, `GooeyPinDemoTests.swift`
- Implementation: 删除四方向 segmented Picker；舞台标题显示真实表面间距与实时角度。两个 AX 元素分别提供上下左右移动；融合/分离动作移动最后选中的 Pin，普通手势不自动吸附。恢复默认重置两个坐标、参数和状态。
- Verification: 状态恢复测试、AX 树检查、融合/分离动作、Debug build 和 `git diff --check`。

### Task 4: 随机可见 Pin 布局与通用稳定数字融合/分离
- Files: `GooeyPinDemoView.swift`, `GooeyPinDemoTests.swift`
- Implementation: `GooeyPinRandomLayoutGenerator` 将请求的可见 Pin 数量 clamp 到 `2...12`。其中两枚保留主示例语义，其余补充 Pin 随机生成单数字或多数字聚合文本和归一化位置；全部 frame 一次性绘入同一 Gooey Canvas，并各自拥有锁定手势目标。数字层把每个 Pin 拆成稳定成员，按胶囊真实表面间距选择当前融合对；拖拽中优先包含活动 Pin 的候选对，松手后保留最后交互目标，脱离后再按新位置重选。单体插入聚合时按当前相对方位计算槽位，两个聚合 Pin 则按相对位置拼接成员组并移动到未拖动的 Pin。
- Verification: 固定种子检查可见数量严格等于请求值、`2...12` clamping、聚合 Pin 只计一个、补充 Pin id 唯一、文本非空、坐标有限、参数保留，以及空间排序、目标重选、活动 Pin 优先级、聚合对聚合成员/分隔符动画和连续坐标回归。

### Task 5: 模拟地图视角和首页贴边
- Files: `GooeyPinDemoView.swift`, `GooeyPinDemoTests.swift`
- Implementation: 空白舞台使用 DragGesture 更新相机 offset，MagnifyGesture 将缩放限制在 `0.5...3`；Pin 保持固定屏幕尺寸，仅将世界中心围绕视口中心缩放和平移。世界中心越过物理舞台后复用 `MapLibreEdgePinGeometry.landingProjection`、`pointingCorner` 和 `MapLibrePinCornerTransitionGeometry.path`，保证落点与单直角和首页一致。Pin 自身拖拽将屏幕 translation 除以 zoom 写回世界坐标，避免缩放后跟手速度错误。
- Verification: 纯函数检查平移缩放坐标、右边贴边、顶部左端落点与 `.topLeft` 直角，并回归 Pin 自由拖动和 Gooey 数字过渡。

### Task 6: 手动控制与首页自动方式
- Files: `GooeyPinDemoView.swift`, `GooeyPinDemoTests.swift`
- Implementation: 布局面板新增默认开启的“手动控制” Toggle。开启时保留每个 Pin 的独立命中层；关闭时移除全部 Pin 命中与辅助移动动作，让背景 DragGesture/MagnifyGesture 独占输入。Pin 世界坐标不变，首页式相机投影改变屏幕间距；相邻形状进入碰撞区时由现有 Gooey 图层和通用数字层自动融合，离开时反向分离。切换方式会清理进行中的拖拽锚点和上一个手动数字目标；恢复默认重新开启手动控制。
- Verification: 纯函数场景固定两个世界坐标，确认 `1×` 时没有融合候选、缩小到 `0.5×` 后无需修改世界坐标即产生融合候选；聚焦测试构建覆盖 Toggle 接线、条件命中层和既有地图/Gooey 回归。

## API/Data Changes
- 无 API、DTO、数据库、SwiftData、Keychain、网络或业务模型变更。

## Edge Cases
- 两中心重合时沿最近一次有效方向计算辅助动作；尚无方向时默认向右，严禁归一化零向量。
- 完全融合时单体 Pin 命中层置顶，保证可反向拖出；聚合胶囊仍可从其暴露区域拖动。
- 舞台小于标准 Pin 时安全退化为有限 frame；正常舞台保持 32pt 固定高度。
- 滤镜和宽度变化不写回离散方向，只通过归一化位置重新映射到合法中心区域。
- 普通拖拽无松手 snap；弹簧仅用于恢复默认和辅助功能融合/分离动作。
- 数字展示进度不再使用完整的 merge/split 滞回带。外边界由 blur、alpha threshold、stroke 和 merge threshold 估算可见 Gooey 桥的触达距离，内部使用 3...8pt 的短 smoothstep 区间；桥尚未接近可见时数字必须留在原 Pin 中，形成连接后才短促移动。数字位置、胶囊宽度和辅助功能文本共用同一进度。
- 同一时刻数字层只为一个当前候选对执行成员重排；活动拖拽 Pin 的候选对优先于场内其他重叠，避免刚插入的数字被背景融合对抢走。当前 Pin 离开旧对象后，候选对由实时 frame 重新计算，因此可继续插入另一个对象。
- 手势首次命中后锁定 `activeDragPin`；该 Pin 的透明命中层在本次拖拽结束前保持最高层级，另一 Pin 暂停命中，避免两者接近或重叠时单体优先区截断聚合 Pin 的进行中拖拽。新的手势在重叠区仍默认选择单体 Pin。
- 地图手势仅由空白背景接收；Pin 命中层在其上方。缩放只改变世界坐标投影，不缩放 32pt Pin 本身；贴边形状和普通形状进入同一个 Gooey Canvas，直角路径不因融合而临时切换为胶囊。
- 首页自动方式不写回 Pin 的归一化世界坐标，也不保留手动拖拽目标；因此相机缩放可逆，放大后每个数字回到原成员 Pin。手动方式重新开启后沿用这些世界坐标继续编辑。

## Research And License Notes
- [Cuberto/gooey-cell](https://github.com/Cuberto/gooey-cell)（MIT）、[Liquid-Menu-Buttons](https://github.com/Kushalbhavsar/Liquid-Menu-Buttons)（MIT）和 [DBMetaballLoading](https://github.com/dabing1022/DBMetaballLoading)（MIT）仅作为交互/滤镜/几何研究来源。
- 实际实现使用 Apple [Canvas](https://developer.apple.com/documentation/swiftui/canvas) 和 [GraphicsContext.Filter](https://developer.apple.com/documentation/swiftui/graphicscontext/filter) 自行绘制，没有复制第三方完整实现或引入依赖。

## Human Verification
- 分别拖动 aggregate/single 覆盖水平、垂直、斜向、四角和反向拖动。
- 让单体 Pin 围绕聚合 Pin 完成完整一周，检查 359°/0° 连续性。
- 检查完全融合后仍能分别拖出两枚 Pin、180pt 宽度、最大 blur/shadow 和辅助功能动作。
- 分别从远处持续拖动聚合 Pin 和单体 Pin 穿过对方的命中区，确认当前手势不中断；松手后再次从重叠区开始，确认仍可选择单体 Pin。
- 设置不同 Pin 数量并反复随机生成，从多种随机方位融合/分离，确认被抽取数字从正确槽位移动且剩余数字不闪烁、不瞬移。
- 拖拽空白舞台并双指缩放，让 Pin 从四个方向越界及返回，确认首页同规则贴边、顶部/底部单直角稳定且重置视角有效。

## Done Criteria
- 两枚 Pin 均可独立二维自由拖动；相对方位完整覆盖 360°，不再存在四向 Picker 或轴投影。
- 真实胶囊表面间距、滞回、边界和零向量均有自动测试。
- 随机场景的可见 Pin 数量边界、坐标、样式、成员身份、空间顺序和连续槽位过渡均有自动测试。
- 地图平移、缩放、贴边方向和直角选择均有自动测试。
- 手动控制开关可在独立拖 Pin 与相机驱动自动融合之间切换；自动缩放融合不修改世界坐标。
- 聚焦测试、Debug build、模拟器绕行和 AX 验证通过；无业务数据、第三方依赖或生产行为修改。
