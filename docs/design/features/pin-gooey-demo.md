# Feature Implementation: Pin Gooey 360° 双拖拽 Demo

## Goal
交付一个与业务隔离的 SwiftUI 二维实验台：单体圆 Pin 与聚合胶囊 Pin 均可自由拖动，Canvas 根据两个实际 frame 在任意角度连续生成 Gooey 融合轮廓；数字层以稳定成员身份呈现空间排序、融合和分离，聚合宽度复用首页文字测量规则自动伸缩。

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

### Task 4: 稳定数字成员融合/分离
- Files: `GooeyPinDemoView.swift`, `GooeyPinDemoTests.swift`
- Implementation: 内置右侧抽取 `4` 与左上抽取 `3` 两个场景。成员由相对 x/y 与稳定 id 排序；分离态接近融合时，将实际方向的水平分量映射到剩余成员间的插入槽位并保存顺序。从融合态开始向外拖时先锁定原槽位，真实表面间距达到 split threshold 后立即解锁；同一次手势或后续手势再次靠近时，按新的相对方位持续更新插入槽位。融合态、剩余聚合态各自按首页 16pt medium 字体计算自然文字槽位；胶囊宽度在完整串和剩余串的首页测量宽度间随提取进度连续插值。
- Verification: 检查右侧融合 `2.3.7.5.4`、左侧融合 `4.2.3.7.5`、`7.3.8.12 → 7.8.12 + 3`、乱序输入稳定排序、分离顺序锁定、阈值附近连续坐标和场景恢复。

## API/Data Changes
- 无 API、DTO、数据库、SwiftData、Keychain、网络或业务模型变更。

## Edge Cases
- 两中心重合时沿最近一次有效方向计算辅助动作；尚无方向时默认向右，严禁归一化零向量。
- 完全融合时单体 Pin 命中层置顶，保证可反向拖出；聚合胶囊仍可从其暴露区域拖动。
- 舞台小于标准 Pin 时安全退化为有限 frame；正常舞台保持 32pt 固定高度。
- 滤镜和宽度变化不写回离散方向，只通过归一化位置重新映射到合法中心区域。
- 普通拖拽无松手 snap；弹簧仅用于恢复默认和辅助功能融合/分离动作。
- 数字展示进度不再使用完整的 merge/split 滞回带。外边界由 blur、alpha threshold、stroke 和 merge threshold 估算可见 Gooey 桥的触达距离，内部使用 3...8pt 的短 smoothstep 区间；桥尚未接近可见时数字必须留在原 Pin 中，形成连接后才短促移动。数字位置、胶囊宽度和辅助功能文本共用同一进度。
- 手势首次命中后锁定 `activeDragPin`；该 Pin 的透明命中层在本次拖拽结束前保持最高层级，另一 Pin 暂停命中，避免两者接近或重叠时单体优先区截断聚合 Pin 的进行中拖拽。新的手势在重叠区仍默认选择单体 Pin。

## Research And License Notes
- [Cuberto/gooey-cell](https://github.com/Cuberto/gooey-cell)（MIT）、[Liquid-Menu-Buttons](https://github.com/Kushalbhavsar/Liquid-Menu-Buttons)（MIT）和 [DBMetaballLoading](https://github.com/dabing1022/DBMetaballLoading)（MIT）仅作为交互/滤镜/几何研究来源。
- 实际实现使用 Apple [Canvas](https://developer.apple.com/documentation/swiftui/canvas) 和 [GraphicsContext.Filter](https://developer.apple.com/documentation/swiftui/graphicscontext/filter) 自行绘制，没有复制第三方完整实现或引入依赖。

## Human Verification
- 分别拖动 aggregate/single 覆盖水平、垂直、斜向、四角和反向拖动。
- 让单体 Pin 围绕聚合 Pin 完成完整一周，检查 359°/0° 连续性。
- 检查完全融合后仍能分别拖出两枚 Pin、180pt 宽度、最大 blur/shadow 和辅助功能动作。
- 分别从远处持续拖动聚合 Pin 和单体 Pin 穿过对方的命中区，确认当前手势不中断；松手后再次从重叠区开始，确认仍可选择单体 Pin。
- 切换两个数字示例，分别从右侧和左上方反复融合/分离，确认被抽取数字从正确槽位移动且剩余数字不闪烁、不瞬移。

## Done Criteria
- 两枚 Pin 均可独立二维自由拖动；相对方位完整覆盖 360°，不再存在四向 Picker 或轴投影。
- 真实胶囊表面间距、滞回、边界和零向量均有自动测试。
- 两个数字场景的空间顺序、抽取结果、成员身份和连续槽位过渡均有自动测试。
- 聚焦测试、Debug build、模拟器绕行和 AX 验证通过；无业务数据、第三方依赖或生产行为修改。
