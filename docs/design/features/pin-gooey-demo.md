# Feature Implementation: Pin Gooey 360° 双拖拽 Demo

## Goal
交付一个与业务隔离的 SwiftUI 二维实验台：单体圆 Pin 与聚合胶囊 Pin 均可自由拖动，Canvas 根据两个实际 frame 在任意角度连续生成 Gooey 融合轮廓。

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
- Implementation: 为 aggregate/single 建立各自命中区和 DragGesture；每次以手势开始位置加二维 translation 计算，不累积误差。只移动当前 Pin，另一个不动；松手保留落点。两者位置始终 clamp 在各自滤镜安全中心区域，尺寸/padding 变化时自动重映射。
- Verification: 纯函数测试分别移动两 Pin 的 x/y、边角 clamping、极端宽度和 tiny stage；模拟器验证水平、垂直、斜向和完整绕行。

### Task 3: UI、辅助功能和调参迁移
- Files: `GooeyPinDemoView.swift`, `GooeyPinDemoTests.swift`
- Implementation: 删除四方向 segmented Picker；舞台标题显示真实表面间距与实时角度。两个 AX 元素分别提供上下左右移动；融合/分离动作移动最后选中的 Pin，普通手势不自动吸附。恢复默认重置两个坐标、参数和状态。
- Verification: 状态恢复测试、AX 树检查、融合/分离动作、Debug build 和 `git diff --check`。

## API/Data Changes
- 无 API、DTO、数据库、SwiftData、Keychain、网络或业务模型变更。

## Edge Cases
- 两中心重合时沿最近一次有效方向计算辅助动作；尚无方向时默认向右，严禁归一化零向量。
- 完全融合时单体 Pin 命中层置顶，保证可反向拖出；聚合胶囊仍可从其暴露区域拖动。
- 舞台小于标准 Pin 时安全退化为有限 frame；正常舞台保持 32pt 固定高度。
- 滤镜和宽度变化不写回离散方向，只通过归一化位置重新映射到合法中心区域。
- 普通拖拽无松手 snap；弹簧仅用于恢复默认和辅助功能融合/分离动作。

## Research And License Notes
- [Cuberto/gooey-cell](https://github.com/Cuberto/gooey-cell)（MIT）、[Liquid-Menu-Buttons](https://github.com/Kushalbhavsar/Liquid-Menu-Buttons)（MIT）和 [DBMetaballLoading](https://github.com/dabing1022/DBMetaballLoading)（MIT）仅作为交互/滤镜/几何研究来源。
- 实际实现使用 Apple [Canvas](https://developer.apple.com/documentation/swiftui/canvas) 和 [GraphicsContext.Filter](https://developer.apple.com/documentation/swiftui/graphicscontext/filter) 自行绘制，没有复制第三方完整实现或引入依赖。

## Human Verification
- 分别拖动 aggregate/single 覆盖水平、垂直、斜向、四角和反向拖动。
- 让单体 Pin 围绕聚合 Pin 完成完整一周，检查 359°/0° 连续性。
- 检查完全融合后仍能分别拖出两枚 Pin、180pt 宽度、最大 blur/shadow 和辅助功能动作。

## Done Criteria
- 两枚 Pin 均可独立二维自由拖动；相对方位完整覆盖 360°，不再存在四向 Picker 或轴投影。
- 真实胶囊表面间距、滞回、边界和零向量均有自动测试。
- 聚焦测试、Debug build、模拟器绕行和 AX 验证通过；无业务数据、第三方依赖或生产行为修改。
