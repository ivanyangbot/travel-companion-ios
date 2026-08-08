# Feature Implementation: 首页吸边 Pin 动态边界与聚合

## Goal

保留首页普通/边缘 Pin 的动态安全区、碰撞聚合、指向角、选择样式和自动追焦，同时确保所有 merge/split 直接应用 resolver 最新稳定形态，首页没有任何 Gooey 渲染或调度路径。

## Files

- Modify: `Sources/TravelCompanion/Features/Today/MapLibreTodayMap.swift`
- Modify: `Tests/TravelCompanionTests/MapsTests.swift`
- Preserve: `Sources/TravelCompanion/Features/Today/GooeyPinDemoView.swift`、`Tests/TravelCompanionTests/GooeyPinDemoTests.swift`、`Sources/TravelCompanion/ContentView.swift` 和 Demo 工程引用。

## Implementation

### Resolver 与稳定渲染

- `calculatedPinPlacements`、`MapLibreRegularPinGrouping`、`MapLibreProjectedEdgePinGrouping` 和 `MapLibreFinalPinGrouping` 继续决定成员、代表、位置、标签和选择态。
- `applyPinPlacements` 直接更新 proxy coordinate、可见性并配置 `MapLibreNumberedAnnotationView`；聚合成员只由稳定 representative view 显示。
- 保留 `MapLibrePinTransitionGeometry` 的安全区位置动画和 `MapLibrePinCornerTransitionGeometry` 的单 Pin 指向角插值；二者不连接不同 Pin。

### 禁止的首页路径

- 不保留 visual partition snapshot、member-set transition resolver、metaball/path bridge、compound Gooey geometry 或 synthetic clarity snapshot。
- 不安装 screen-space Gooey overlay，不隐藏稳定 annotation 内容，不创建 playback generation、Reduce Motion observer、coalescer、DispatchWorkItem 或短促 fallback。
- 快速缩放、自动追焦、CRUD、选择和 safe-area 更新统一直接使用最新 placement。

### Demo 隔离

- `GooeyPinDemoView` 是唯一 Gooey 实现；只允许复用白色 32pt Pin、橙色描边等静态视觉语言。
- Demo 不得引用 MapLibre annotation、首页 resolver、POI、选择、相机、路线或持久化。

## Verification

```sh
xcodebuild test -project TravelCompanion.xcodeproj -scheme TravelCompanion \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.1' \
  -only-testing:TravelCompanionTests/MapsTests

xcodebuild test -project TravelCompanion.xcodeproj -scheme TravelCompanion \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.1' \
  -only-testing:TravelCompanionTests/GooeyPinDemoTests

xcodebuild build -project TravelCompanion.xcodeproj -scheme TravelCompanion \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.1'
```

- `rg` 确认 production MapLibre 文件和 MapsTests 中无 `MapLibrePinGooey`、metaball、Gooey overlay 或 fallback。
- 模拟器首页连续 pan/zoom 后无液态效果；Demo 仍可从齿轮打开并融合/分离。

