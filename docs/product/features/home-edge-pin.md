# Product Feature: 首页吸边 Pin 动态边界与无重叠聚合

## Description

首页地图中的 Pin 只有在完整视觉外框进入动态安全区时保持普通位置，越界后吸附到安全区边缘。屏内、边缘及两者交界处按真实外框做传递碰撞聚合，拆分结果必须不重叠。placement resolver 是成员、代表、标签、选择和最终位置的唯一权威；任何成员集合变化都直接显示最新稳定形态。

## Boundary

### Included

- 左右 20pt、上 160pt；下边界跟随时间轴或浮动 Tab Bar。
- 上下边只使用左右端点槽位，并保留上左、上右、下左、下右对应的指向直角。
- 卡片/覆盖层改变安全区时保留现有 Pin 位移和指向角圆角插值。
- 屏内、边缘和 regular/edge seam 按真实渲染外框做碰撞闭包。
- 超宽聚合使用稳定前缀加 `+N`，保留完整成员 ID。
- 高亮类别圆、数字圆、橙色描边、32pt 标准高度及自动追焦保持现状。
- merge/split、快速缩放、自动追焦和安全区变化直接应用 resolver 最新结果。

### Excluded

- 首页 Gooey、metaball、液态桥、blur/alpha threshold、融合/分离淡变、临时 overlay、clarity 副本、播放生命周期、coalescer、延迟 fallback 或 annotation 内容隐藏。
- 首页 Pin 直接拖拽、生产调参面板或把独立 Demo 的状态机接入地图。
- 修改碰撞阈值、聚合成员、顺序、代表 ID、标签、选择、相机、路线、POI 数据、持久化或后端。

## Acceptance Criteria

- 完整外框满足左右 20pt、上 160pt，并位于动态下边界上方 20pt。
- 卡片或整体覆盖层展开/收起时，边缘 Pin 沿现有普通位置动画移动；地图手势期间保持跟手。
- 上下边只有左右端点；跨屏幕中心后进入另一端，四个端点的指向直角保持正确。
- 最终外框相撞即聚合，拆分后两两不重叠；成员、顺序、代表、标签和选择身份不丢失。
- 普通与聚合 Pin 高度为 32pt；聚合宽度随标签变化；选中态类别圆和橙色描边保持。
- 任意 pan/zoom、快速往返阈值、自动追焦或安全区变化导致 merge/split 时立即显示最终 Pin，不出现液态桥、拉伸、模糊、淡变、残影或延迟补播。
- 首页运行时不创建 Gooey overlay、transition snapshot、metaball path、Timer/WorkItem、clarity layer 或临时辅助功能元素。
- 自动定位继续放大直到目标成为独立 Pin；用户手势会取消未完成的自动追焦。
- 独立 Gooey Demo 可正常打开，但其状态和渲染不进入首页。

## Verification

- `MapsTests` 覆盖安全区、位置/指向角动画、上下端点、碰撞闭包、成员守恒、超宽标签、高亮尺寸和自动追焦。
- 静态检索确认 `MapLibreTodayMap.swift` 与 `MapsTests.swift` 不包含 production Gooey 类型或调用。
- 模拟器验证首页连续 pan/zoom 只显示稳定 Pin，并打开独立 Demo 确认 Gooey 仍正常。

