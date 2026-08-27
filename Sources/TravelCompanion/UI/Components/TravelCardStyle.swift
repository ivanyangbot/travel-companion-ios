import CoreText
import SwiftUI

enum PrimaryTabPalette {
    static let background = Color.black
    static let surface = Color(red: 23 / 255, green: 23 / 255, blue: 23 / 255)
    static let elevatedSurface = Color(red: 34 / 255, green: 34 / 255, blue: 34 / 255)
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.38)
    static let divider = Color.white.opacity(0.055)
    static let accent = Color(red: 1, green: 110 / 255, blue: 0)
}

struct TravelCardStyle: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(red: 0.095, green: 0.10, blue: 0.115),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.045), lineWidth: 1)
            }
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(tint)
                    .frame(width: 4)
                    .padding(.vertical, 14)
                    .padding(.leading, 2)
            }
    }
}

extension View {
    func travelCardStyle(tint: Color) -> some View {
        modifier(TravelCardStyle(tint: tint))
    }

    func primaryTabHeaderButtonStyle() -> some View {
        self
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .background { TodayGlassBackdrop() }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.6), lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(
                color: Color(red: 24 / 255, green: 22 / 255, blue: 82 / 255).opacity(0.1),
                radius: 12,
                y: 12
            )
            .buttonStyle(.plain)
    }

    func primaryTabCardStyle(
        color: Color = PrimaryTabPalette.surface,
        cornerRadius: CGFloat = 16
    ) -> some View {
        self
            .background(color, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.035), lineWidth: 1)
            }
    }
}

// MARK: - Agent 初始页视觉（ASCII 背景与旋转地球，Demo 与 Agent 页共用）

/// 静态 ASCII 底纹：按网格坐标哈希取字符，内容稳定、只随布局尺寸重绘。
struct AgentIntroASCIIBackgroundView: View {
    private let cell: CGFloat = 16

    var body: some View {
        Canvas { context, size in
            let columns = Int((size.width / cell).rounded(.up))
            let rows = Int((size.height / cell).rounded(.up))
            for row in 0 ... rows {
                for column in 0 ... columns {
                    AgentASCIIGlyphRenderer.draw(
                        Self.glyph(column: column, row: row),
                        in: &context,
                        at: CGPoint(x: (CGFloat(column) + 0.5) * cell, y: (CGFloat(row) + 0.5) * cell),
                        fontSize: 12,
                        color: .white.opacity(0.22)
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }

    private static let glyphPool: [Character] = Array("01·:+*")

    private static func glyph(column: Int, row: Int) -> Character {
        let seed = UInt(bitPattern: (column &* 2_654_435_761) ^ (row &* 2_246_822_519))
        return glyphPool[Int(seed % UInt(glyphPool.count))]
    }
}

/// Draws monospaced characters as cached vector outlines instead of SwiftUI
/// `Text`. On physical devices, each `GraphicsContext.draw(Text(...))` call is
/// registered synchronously by `AXUIContextDrawingAnnotation`; the animated
/// globe can issue hundreds of those calls per frame and stall the main run
/// loop for seconds. Filling glyph paths preserves the ASCII appearance while
/// keeping the drawing out of the system text-annotation pipeline.
private enum AgentASCIIGlyphRenderer {
    private static let baseFontSize: CGFloat = 12
    private static let characters = Array(Set("01·:+* .:;',wiogOLXHWYV@"))
    private static let outlines: [Character: Path] = {
        let font = CTFontCreateWithName("SFMono-Regular" as CFString, baseFontSize, nil)
        return Dictionary(uniqueKeysWithValues: characters.compactMap { character in
            guard let codeUnit = String(character).utf16.first else { return nil }
            var unicode = codeUnit
            var glyph = CGGlyph()
            guard CTFontGetGlyphsForCharacters(font, &unicode, &glyph, 1),
                  let glyphPath = CTFontCreatePathForGlyph(font, glyph, nil) else { return nil }
            let bounds = glyphPath.boundingBoxOfPath
            guard !bounds.isNull, !bounds.isEmpty else { return nil }
            var transform = CGAffineTransform(
                a: 1,
                b: 0,
                c: 0,
                d: -1,
                tx: -bounds.midX,
                ty: bounds.midY
            )
            guard let centeredPath = glyphPath.copy(using: &transform) else { return nil }
            return (character, Path(centeredPath))
        })
    }()

    static func draw(
        _ character: Character,
        in context: inout GraphicsContext,
        at point: CGPoint,
        fontSize: CGFloat,
        color: Color
    ) {
        guard let outline = outlines[character] else { return }
        var glyphContext = context
        glyphContext.translateBy(x: point.x, y: point.y)
        let scale = fontSize / baseFontSize
        glyphContext.scaleBy(x: scale, y: scale)
        glyphContext.fill(outline, with: .color(color))
    }
}

/// 地球自转控制器：自动匀速自转 + 用户沿赤道（水平）拖动的相位偏移。
/// 纯可变状态、不经 SwiftUI 观察——地球视图的 TimelineView 以 30fps 重绘，
/// 拖动更新最迟下一帧呈现。把同一实例注入欢迎页大地球与对话页英雄位，
/// 拖动相位即可跨视图连续（matched 变形时旋转不跳变）。
///
/// 连续性设计：拖动期间自动分量完全冻结（rotation 只返回 userPhase），
/// 抓取瞬间把此前累计的自动分量一次性并入相位、松手时把零点重置为当前
/// 墙钟——抓取、拖动、松手三个边界都严格连续。不使用 DragGesture 的
/// value.time 折叠时间：其语义在不同系统版本上并不稳定，一旦与真实时钟
/// 有偏差，拖动期间渲染出的「自动蠕变」会在松手重置零点时整体丢失，地
/// 球跳回拖动前的相位（即「松手后不从松手位置继续旋转」）。
final class AgentGlobeSpin {
    /// 自动自转角速度（弧度/秒），与最初的 0.35 rad/s 一致。
    private static let autoSpeed: Double = 0.35
    /// 渲染器中球体半径系数（min 边 / 2 × 0.94）：拖动位移换算旋转弧度用，
    /// 让赤道上的表面点与手指同速移动。
    private static let radiusFactor: Double = 0.94

    /// 自动分量的计时零点（上次拖动结束的时刻）。
    private var epoch: Date = .now
    /// 用户拖动累计的旋转相位（弧度）。
    private(set) var userPhase: Double = 0
    /// 是否正在拖动：拖动期间自动分量冻结，rotation 只返回用户相位。
    private var isDragging = false
    /// 上一次拖动事件的水平位移（增量换算用）。
    private var lastDragX: CGFloat = 0

    /// date 时刻的累计旋转角：拖动中＝用户相位；松手后＝用户相位 + 自
    /// 松手时刻起算的自动分量。
    func rotation(at date: Date) -> Double {
        isDragging
            ? userPhase
            : date.timeIntervalSince(epoch) * Self.autoSpeed + userPhase
    }

    /// 拖动跟随：首个事件先把此前累计的自动分量并入相位（无缝接管，之后
    /// 自动分量冻结），每个事件按水平位移增量换算弧度。
    func drag(translation: CGSize, globeDiameter: CGFloat) {
        if !isDragging {
            userPhase += Date.now.timeIntervalSince(epoch) * Self.autoSpeed
            isDragging = true
        }
        let radius = max(1, Double(globeDiameter) / 2 * Self.radiusFactor)
        userPhase += Double(translation.width - lastDragX) / radius
        lastDragX = translation.width
    }

    /// 拖动结束：零点重置为当前墙钟，从松手位置的相位继续自动自转。
    func endDrag() {
        guard isDragging else { return }
        lastDragX = 0
        isDragging = false
        epoch = .now
    }
}

/// 旋转 ASCII 地球：贴图与昼夜混合参考 globe-master（真实地球贴图 +
/// 顶部光源昼夜过渡），字符本体附着在 Fibonacci 球面采样点上，
/// 经自转与地轴倾角变换后做透视投影，随深度产生缩放与透明度衰减。
/// 支持沿赤道拖动：水平拖动直接旋转球体、方向跟手，拖动期间自动自转
/// 冻结，松手后从当前角度继续。
struct AgentIntroGlobeView: View {
    let diameter: CGFloat
    /// 自转/拖动状态；nil 时使用内部自建实例（Demo 等无跨视图连续性场景）。
    var spin: AgentGlobeSpin? = nil

    @State private var ownSpin = AgentGlobeSpin()

    private var activeSpin: AgentGlobeSpin { spin ?? ownSpin }

    var body: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 1 / 30)) { context in
                Canvas { canvas, size in
                    let rotation = activeSpin.rotation(at: context.date)
                        .truncatingRemainder(dividingBy: .pi * 2)
                    AgentIntroGlobeRenderer.draw(
                        context: &canvas,
                        size: size,
                        rotation: rotation
                    )
                }
            }
            // Hundreds of ASCII glyphs are drawn each frame. Hide the drawing
            // itself and expose only the stable semantic wrapper below.
            .accessibilityHidden(true)
        }
        .frame(width: diameter, height: diameter)
        .globeEquatorDrag(spin: activeSpin, diameter: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("a11y.globe"))
    }
}

extension View {
    /// 地球沿赤道拖动手势：水平位移按球面半径换算为自转角（表面点跟手
    /// 同速），命中区收窄到圆形。用 simultaneousGesture 与外层 ScrollView
    /// 的竖直滚动互不抢占——竖直滑动照常滚动页面，水平滑动只转地球。
    func globeEquatorDrag(spin: AgentGlobeSpin, diameter: CGFloat) -> some View {
        contentShape(Circle())
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        spin.drag(translation: value.translation, globeDiameter: diameter)
                    }
                    .onEnded { value in
                        // 松手前的最后一段位移也计入（onEnded 的 translation
                        // 是最终累计值），再从当前角度恢复自动自转。
                        spin.drag(translation: value.translation, globeDiameter: diameter)
                        spin.endDrag()
                    }
            )
    }
}

enum AgentIntroGlobeRenderer {
    private static let tilt = 23.5 * Double.pi / 180

    // 光照方向以观察者为主、略偏左上：整个球面以白天贴图为主，
    // 仅在边缘与右下背光处平滑过渡到黑夜贴图，避免昼夜分界线压在赤道上。
    private static let light: (x: Double, y: Double, z: Double) = {
        let raw = (x: -0.55, y: 0.4, z: 1.0)
        let length = (raw.x * raw.x + raw.y * raw.y + raw.z * raw.z).squareRoot()
        return (raw.x / length, raw.y / length, raw.z / length)
    }()

    static func draw(context: inout GraphicsContext, size: CGSize, rotation: Double) {
        let radius = Double(min(size.width, size.height)) / 2 * 0.94
        guard radius > 0 else { return }
        let centerX = Double(size.width) / 2
        let centerY = Double(size.height) / 2
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        let cosT = cos(tilt)
        let sinT = sin(tilt)

        for point in AgentIntroEarthTexture.samples {
            // 自转（绕竖直轴）+ 地轴倾角
            let rotatedX = point.x * cosR + point.z * sinR
            let rotatedZ = -point.x * sinR + point.z * cosR
            let tiltedY = point.y * cosT - rotatedZ * sinT
            let tiltedZ = point.y * sinT + rotatedZ * cosT
            guard tiltedZ > 0 else { continue }

            // 光照决定昼夜贴图混合比例（法线即单位球面位置向量）
            let diffuse = rotatedX * Self.light.x + tiltedY * Self.light.y + tiltedZ * Self.light.z
            let luminance = min(1, max(0, 0.15 + 1.15 * diffuse))
            let sampled = AgentIntroEarthTexture.sample(
                longitude: point.longitude,
                sineLatitude: point.y
            )
            let blended = (1 - luminance) * sampled.night + luminance * sampled.day
            let index = min(
                AgentIntroEarthTexture.palette.count - 1,
                max(0, Int(blended.rounded()))
            )
            let glyph = AgentIntroEarthTexture.palette[index]
            guard glyph != " " else { continue }

            // 透视深度：越靠边缘的字符越小越淡
            let depth = tiltedZ
            AgentASCIIGlyphRenderer.draw(
                glyph,
                in: &context,
                at: CGPoint(x: centerX + rotatedX * radius, y: centerY - tiltedY * radius),
                fontSize: 12 * (0.78 + 0.32 * depth),
                color: PrimaryTabPalette.accent.opacity(0.4 + 0.6 * depth)
            )
        }
    }
}

/// ASCII 思考 orb 渲染器：与 Vendor/ThinkingOrbsKit 共用同一套引擎
/// （resolvePreset + orbFrame），把圆点画成等宽 "." 字符、连线按线段
/// 绘制。字号与墨色都对齐 ASCII 地球的语言——主题橙、透明度随引擎的
/// 深度墨值变化、字号夹取在地球字符的量级——供顶部英雄位在地球与思考
/// 动效之间无痕交叉溶解。
enum AgentIntroOrbRenderer {
    /// 点半径 → 字号的比例（64pt 预设坐标系）：多数点半径在 0.3–1.6 之间，
    /// 该比例让句点墨迹落在地球字符（约 12pt）的量级附近。
    private static let glyphScale: Double = 5.5
    /// 字号夹取（预设坐标系）：远端小点不缩成亚像素，近端大点不糊成团。
    private static let fontSizeRange: ClosedRange<Double> = 3.5...9
    static func draw(
        into context: inout GraphicsContext,
        state: OrbState,
        clock: Double,
        tint: Color,
        alpha: Double = 1
    ) {
        guard alpha > 0.01 else { return }
        let orbSize = OrbSize.px64
        let preset = resolvePreset(state, orbSize)
        let frame = orbFrame(preset, size: orbSize.value, t: clock * preset.speed)
        // 连线先画，点叠在线上（与 ThinkingOrb 的绘制顺序一致）。
        for line in frame.lines {
            var path = Path()
            path.move(to: CGPoint(x: line.x1, y: line.y1))
            path.addLine(to: CGPoint(x: line.x2, y: line.y2))
            context.stroke(
                path,
                with: .color(tint.opacity(inkAlpha(line.white, line.a * alpha))),
                lineWidth: line.w
            )
        }
        for dot in frame.dots {
            let fontSize = min(fontSizeRange.upperBound, max(fontSizeRange.lowerBound, dot.r * glyphScale))
            AgentASCIIGlyphRenderer.draw(
                ".",
                in: &context,
                at: CGPoint(x: dot.x, y: dot.y),
                fontSize: fontSize,
                color: tint.opacity(inkAlpha(dot.white, dot.a * alpha))
            )
        }
    }

    /// 引擎墨值（0 = 纸上最深的墨，暗色主题按亮度镜像）映射为透明度：
    /// 越亮的点越实，保底 0.4 维持云团可读。
    private static func inkAlpha(_ white: Double, _ alpha: Double) -> Double {
        let brightness = 1 - min(1, max(0, white))
        return min(1, max(0, alpha * (0.4 + 0.6 * brightness)))
    }
}

/// 对话页顶部英雄位：ASCII 地球与 ASCII 思考 orb 在同一个 Canvas 内交叉
/// 溶解——共用主题橙、等宽字符与相近字号，视觉上是同一物体在两种动效间
/// 渐变，而非两个图标的切换。thinkingState 为 nil 时只呈现地球；变化时
/// 旧视觉淡出并轻微放大、新视觉自 0.94 缩放着淡入，进度由 TimelineView
/// 的帧时钟驱动（不经过 SwiftUI 动画），Canvas 每帧都能取到连续中间值。
struct AgentHeroGlobeView: View {
    /// 当前思考状态（nil = 旋转地球）。
    var thinkingState: OrbState?
    let diameter: CGFloat
    /// 自转/拖动状态；与欢迎页大地球共用同一实例时，拖动相位跨视图连续。
    var spin: AgentGlobeSpin? = nil

    @State private var ownSpin = AgentGlobeSpin()
    @State private var previousThinkingState: OrbState?
    @State private var transitionStartedAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 显式构造器：@State 私有属性会让合成的 memberwise init 一并变私
    /// 有，跨文件调用（AgentHomeView 等）需要这个公开签名。
    init(thinkingState: OrbState?, diameter: CGFloat, spin: AgentGlobeSpin? = nil) {
        self.thinkingState = thinkingState
        self.diameter = diameter
        self.spin = spin
    }

    /// 交叉溶解时长（秒）。
    private static let crossfadeDuration: Double = 0.55

    private var activeSpin: AgentGlobeSpin { spin ?? ownSpin }

    var body: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 1 / 30)) { timeline in
                Canvas(rendersAsynchronously: false) { context, size in
                    let date = timeline.date
                    let blend = blend(at: date)
                    drawLayer(
                        previousThinkingState, into: context, size: size, date: date,
                        alpha: 1 - blend, scale: 1 + 0.06 * blend
                    )
                    drawLayer(
                        thinkingState, into: context, size: size, date: date,
                        alpha: blend, scale: 0.94 + 0.06 * blend
                    )
                }
            }
            .accessibilityHidden(true)
        }
        .frame(width: diameter, height: diameter)
        // 地球呈现期间支持沿赤道拖动（思考 orb 不受拖动影响）。
        .globeEquatorDrag(spin: activeSpin, diameter: diameter)
        .onChange(of: thinkingState) { oldValue, newValue in
            guard oldValue != newValue else { return }
            previousThinkingState = oldValue
            transitionStartedAt = .now
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(thinkingState?.label ?? String(localized: "a11y.globe")))
    }

    /// 溶解进度（smoothstep 缓动，起止速度为 0）；无过渡或用户开启
    /// 「减弱动态效果」时恒为 1（直接呈现当前视觉）。
    private func blend(at date: Date) -> Double {
        guard !reduceMotion, let start = transitionStartedAt else { return 1 }
        let progress = min(1, max(0, date.timeIntervalSince(start) / Self.crossfadeDuration))
        return progress * progress * (3 - 2 * progress)
    }

    /// 画一层视觉：nil = 旋转地球（复用 AgentIntroGlobeRenderer，旋转来自
    /// spin 实例——与 AgentIntroGlobeView 共用时从欢迎页 matched 变形过来
    /// 相位连续），非 nil = 对应状态的 ASCII 思考 orb（画在 64pt 预设坐标
    /// 系里再整体缩放到画布，保持矢量清晰）。
    private func drawLayer(
        _ state: OrbState?,
        into context: GraphicsContext,
        size: CGSize,
        date: Date,
        alpha: Double,
        scale: Double
    ) {
        guard alpha > 0.01 else { return }
        var context = context
        if scale != 1 {
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -size.width / 2, y: -size.height / 2)
        }
        if let state {
            let zoom = min(size.width, size.height) / OrbSize.px64.value
            context.scaleBy(x: zoom, y: zoom)
            let clock = reduceMotion ? OrbSpec.reducedMotionT : date.timeIntervalSinceReferenceDate
            AgentIntroOrbRenderer.draw(into: &context, state: state, clock: clock, tint: PrimaryTabPalette.accent, alpha: alpha)
        } else {
            context.opacity *= alpha
            let rotation = activeSpin.rotation(at: date).truncatingRemainder(dividingBy: .pi * 2)
            AgentIntroGlobeRenderer.draw(context: &context, size: size, rotation: rotation)
        }
    }
}

/// 地球贴图数据，内容来自 globe-master 的 earth.txt / earth_night.txt
///（300×76，等距圆柱投影，首列为 180°W、向东递增，首行为北极）。
/// 按 palette 下标（0...H）逐行 RLE 编码，避免长串空白字符在源码中丢失。
enum AgentIntroEarthTexture {
    static let width = 300
    static let height = 76
    static let palette: [Character] = Array(" .:;',wiogOLXHWYV@")

    private static let dayRLE = """
    1686,D1,126,D16,1241,D5,13,95,H9,96,13,910,H18,93,16,D2,148,D5,12,D3,11,D5,123,D4,1125,D3,13,D1,11,D5,11,91,11,91,H1,91,H1,92,H1,91,H7,91,17,91,H36,91,12,D1,125,91,11,95,13,D2,116,D3,14,D4,126,D1,13,91,12,D1,12,D2,1110,D1,18,D8,13,D2,12,D1,11,91,12,97,11,D1,14,D1,11,98,H32,91,128,D1,13,D1,11,D3,130,D7,120,D7,94,15,D2,120,D4,177,D1,111,D2,12,D2,11,D1,11,91,11,D1,92,11,92,11,93,11,93,11,D2,115,D1,11,91,H28,91,11,D1,160,D1,11,92,11,D2,115,D5,95,H12,95,11,D3,15,D2,18,D2,15,D1,11,D4,124,D2,117,D1,125,D1,94,11,91,H2,95,11,91,H1,91,11,D2,11,92,11,92,11,D1,11,91,H2,92,H2,93,H1,91,11,D3,113,91,H24,91,H1,91,161,D1,91,H1,91,D1,18,D1,93,11,D1,91,D1,11,91,11,93,H29,94,H4,91,12,D6,11,94,14,D2,122,D2,111,D2,11,94,H1,97,17,D5,14,91,16,D2,11,93,H5,94,D3,12,93,11,D2,13,H2,91,14,91,H4,92,112,93,H20,91,12,D1,130,D3,12,99,12,D3,19,D2,12,D5,14,D3,91,H3,12,H46,92,H17,96,18,D1,16,D2,94,D4,13,D1,11,92,H39,96,H3,95,H2,91,H5,91,11,91,H2,91,13,D1,13,91,H4,92,12,D1,16,91,H15,91,11,D3,110,D1,125,91,H15,95,11,D3,91,11,D1,94,H1,93,H1,91,H6,91,H3,91,11,H88,D3,11,92,11,D1,12,D1,11,94,H59,92,11,92,11,D2,14,D1,11,91,H4,13,D1,17,D1,11,H9,91,D3,111,97,D1,119,D1,11,91,H6,91,D1,11,91,H8,14,92,H1,91,H111,91,18,D2,12,D1,11,93,H56,91,11,D1,13,D2,11,D1,11,D2,12,D1,11,D1,12,92,12,D1,110,D1,91,H5,91,D1,117,D3,18,D1,19,D1,11,92,H6,91,11,D2,92,H111,92,H2,92,H7,93,12,D1,111,D1,11,92,H7,95,13,95,H36,D1,113,91,H4,92,D1,12,D1,113,D2,12,91,D1,139,91,H9,91,D1,11,D1,96,H95,97,H2,91,11,D1,14,93,15,D1,121,D2,11,92,11,91,11,D1,111,D1,91,H34,91,11,D3,110,H6,93,H2,91,D1,147,91,11,D1,15,D1,15,91,H3,D2,14,91,H94,92,11,D1,17,D2,12,D1,11,92,H1,91,D1,126,D3,11,D2,12,D1,115,D1,11,92,H34,92,12,D3,11,D2,11,H13,11,D2,141,D1,11,92,H1,18,D1,92,11,92,12,D3,91,H95,91,11,D1,113,D1,H4,91,D1,123,D3,128,D1,11,91,H38,91,D1,11,91,H17,91,D1,137,D1,91,H1,91,D1,11,91,H1,91,13,D1,12,91,H2,95,H1,91,H97,94,12,D1,110,91,H1,11,D1,159,92,H37,92,H10,96,12,91,138,D3,11,D1,11,92,11,91,11,92,H113,D1,92,19,D1,11,D1,162,D1,11,92,H44,94,D3,11,D1,94,141,D1,11,93,H115,91,11,91,D1,177,H47,91,H1,91,16,D3,143,H11,92,H12,91,12,91,H1,91,11,91,H7,91,12,D1,11,91,H69,91,D1,13,D1,177,H44,91,11,D2,11,D2,144,D1,13,D2,11,H4,93,13,H1,91,12,92,H8,91,D1,12,D3,11,D1,11,92,H4,14,91,H65,94,D1,13,D1,92,11,D2,174,H41,92,11,D1,151,H7,91,16,91,11,D1,14,D2,91,H2,93,H1,14,93,11,D3,91,H5,91,D1,11,D1,11,91,H54,92,H5,91,D1,17,D1,91,D2,176,D1,91,H39,91,D1,153,91,H6,91,12,D1,18,D2,91,D1,11,D1,91,H1,91,D1,11,91,H18,D1,13,H53,91,D2,11,D2,91,H1,91,D1,19,91,D1,179,91,H37,91,155,D2,11,91,13,D2,16,92,12,D2,14,D1,12,D3,11,91,12,92,11,H11,91,13,H54,91,11,D1,12,D1,91,H1,91,13,D3,92,H1,184,91,H32,91,11,D1,156,D1,11,H1,93,H9,91,D1,117,D1,12,H69,91,D1,17,D1,11,92,11,91,11,D2,186,H1,92,H26,11,D1,158,91,H17,93,D2,11,D1,93,11,D8,H72,D1,18,D1,192,D1,91,11,91,H12,92,13,91,11,D3,12,H1,158,D1,11,H23,92,H23,11,D1,91,H58,1103,D1,91,11,D1,91,H10,D1,111,91,H1,D1,155,91,H38,12,91,H9,91,D3,94,H52,1108,D2,91,H7,91,116,D1,152,H41,D2,91,H10,91,D2,11,91,D4,11,D3,11,91,H41,91,D3,1106,D1,13,H6,91,110,D3,13,D1,150,91,H42,91,13,H15,91,19,91,H1,91,H12,94,H13,91,H1,93,12,D1,171,D1,142,91,H6,16,H2,17,D1,12,D2,12,D1,144,91,H44,13,H14,110,D2,11,H9,92,D1,15,H10,91,D2,91,D1,1120,D1,12,91,H3,94,H2,91,18,D1,12,D2,11,D2,11,D2,11,D1,139,H44,91,D1,11,D1,91,H8,92,11,D1,112,D1,H7,91,11,D1,18,H1,91,H7,91,D3,19,91,1116,D4,11,H3,94,D1,117,D1,131,D1,14,D1,91,H45,91,11,D1,11,H5,91,11,D1,118,H5,D1,110,D2,12,H8,110,91,1123,D2,11,91,H2,110,D2,144,91,H48,11,91,11,D3,121,91,H3,91,110,D1,13,D1,H1,11,92,H5,D1,112,D1,1124,H1,18,91,H1,11,92,12,D1,13,D1,136,D1,11,91,H47,13,93,121,91,H2,115,D1,91,14,91,H1,11,D1,18,D1,11,D1,91,1129,91,12,92,H3,91,H8,91,139,91,H51,91,121,D1,11,D1,11,91,113,D1,91,14,D1,19,D2,15,91,D1,1130,H15,91,13,D1,134,D1,11,91,H2,93,H1,91,12,D2,91,H35,91,125,D1,112,D3,12,91,112,91,11,D1,11,D1,11,D1,11,D1,1129,91,H21,136,D1,111,D3,H30,91,142,91,11,D1,91,H1,D1,16,D1,11,H3,D1,1134,D1,91,H23,D1,148,D1,H28,91,D1,143,D1,91,H1,93,13,D1,92,H5,12,D4,12,91,D1,1115,D2,17,D1,H24,91,H1,92,11,D1,145,H26,91,D1,146,D1,11,H2,91,D2,12,91,H5,16,D2,13,D1,11,91,12,D3,16,D1,1109,D1,H31,93,11,D1,139,D1,91,H23,D1,149,D2,91,H2,11,D1,12,D1,16,91,11,91,D1,12,D4,11,D1,91,11,91,H4,91,11,D1,16,D1,1105,H36,92,139,91,H21,91,153,D1,13,D5,14,D4,18,D2,11,D1,91,H5,91,11,D2,11,D1,12,D1,1103,D1,91,H35,91,139,D1,H22,156,D3,13,D9,11,D1,13,D1,17,93,D1,11,91,12,D1,14,D5,1100,91,H33,142,91,H21,166,D2,11,D2,14,D3,112,D3,17,D2,1101,91,H30,91,D1,141,D1,91,H21,91,171,D1,13,91,H2,92,14,H1,1119,91,H28,143,91,H22,91,13,D1,11,91,H1,91,161,D1,91,H1,92,H5,11,D1,12,D1,H2,91,D1,117,D2,18,D1,189,D1,11,91,H25,D1,141,D1,H20,91,11,D1,13,D1,H4,D1,159,D1,91,H12,93,H3,91,118,D1,18,D1,192,H24,144,D1,91,H17,D1,16,D1,H3,91,155,D2,12,91,H21,91,11,D1,112,D1,1103,91,H20,93,146,D1,H17,17,91,H2,91,154,D1,91,H28,91,113,D1,1102,91,H17,91,11,D1,150,91,H14,91,11,D1,16,D1,92,D1,155,H31,91,D1,1112,D1,H18,153,D1,91,H13,D1,166,D1,H32,91,1113,H17,155,D1,91,H10,91,D1,168,D1,H31,91,1112,91,H15,91,D1,156,D1,H8,91,172,91,H6,93,12,D2,11,91,H14,91,D1,1111,D1,H11,94,D1,160,91,14,D2,174,92,11,D4,110,92,H9,91,D1,117,D1,193,D1,91,H12,1162,D1,12,H6,92,D1,118,D1,12,D2,189,D1,H9,13,D1,1165,D2,11,D1,11,D2,122,H1,11,D1,190,91,H5,91,1174,D1,92,119,D1,91,11,D1,193,91,H4,92,D1,1174,D1,11,D1,115,D1,11,92,11,D1,193,H5,91,1196,91,11,D1,194,91,H5,91,1113,D1,1179,91,H4,91,D1,15,D3,1285,D1,11,93,H1,11,D1,15,D1,1289,D2,12,D1,1904,D5,1291,D1,11,91,11,D4,190,D4,136,D4,15,D3,1147,D1,11,92,11,D1,187,D3,13,91,H5,92,18,D1,17,D3,12,914,H4,94,H3,913,H6,96,12,D1,12,D1,12,D1,1108,D3,92,12,H3,91,11,D1,144,D1,12,D1,14,D11,11,D2,11,D9,11,92,14,91,H22,92,11,D2,12,92,H61,92,H1,94,11,D6,174,D2,14,D7,16,D1,12,D1,13,93,11,H5,138,D2,11,91,H1,92,H1,92,H1,93,H55,13,91,H79,92,137,D1,11,D1,12,D3,18,92,12,91,11,91,11,91,11,91,13,D6,12,91,H12,93,H3,92,H9,92,11,D1,132,D3,11,91,H148,91,12,D1,129,D1,13,D2,12,93,H57,91,11,91,13,D3,115,D2,19,D1,13,94,H156,91,D1,11,D3,122,D1,11,D2,12,D1,14,92,H55,95,D2,12,D1,11,D1,11,D2,12,D2,16,D1,11,91,H4,91,15,D1,13,95,H155,91,11,D4,125,D2,13,D2,11,93,H62,93,H1,94,14,D1,13,D2,16,D3,11,96,H163,12,D2,115,D2,18,97,H79,93,H188,95,15,H600
    """

    private static let nightRLE = """
    0686,11,026,116,0241,15,03,35,29,36,03,310,218,33,06,12,048,15,02,13,01,15,023,14,0125,13,03,11,01,15,01,31,01,31,21,31,21,32,21,31,27,31,07,31,236,31,02,11,025,31,01,35,03,12,016,13,04,14,026,11,03,31,02,11,02,12,0110,11,08,18,03,12,02,11,01,31,02,37,01,11,04,11,01,38,232,31,028,11,03,11,01,13,030,17,020,17,34,05,12,020,14,077,11,011,12,02,12,01,11,01,31,01,11,32,01,32,01,33,01,33,01,12,015,11,01,31,228,31,01,11,060,11,01,32,01,12,015,15,35,212,35,01,13,05,12,08,12,05,11,01,14,024,12,017,11,025,11,34,01,31,22,35,01,31,21,31,01,12,01,32,01,32,01,11,01,31,22,32,22,33,21,31,01,13,013,31,224,31,21,31,061,11,31,21,31,11,08,11,33,01,11,31,11,01,31,01,33,229,34,24,31,02,16,01,34,04,12,022,12,011,12,01,34,21,37,07,15,04,31,06,12,01,33,25,34,13,02,33,01,12,03,22,31,04,31,24,32,012,33,220,31,02,11,030,13,02,39,02,13,09,12,02,15,04,13,31,23,02,246,32,217,36,08,11,06,12,34,14,03,11,01,32,239,36,23,35,22,31,25,31,01,31,22,31,03,11,03,31,24,32,02,11,06,31,215,31,01,13,010,11,025,31,215,35,01,13,31,01,11,34,21,33,21,31,26,31,23,31,01,288,13,01,32,01,11,02,11,01,34,259,32,01,32,01,12,04,11,01,31,24,03,11,07,11,01,29,31,13,011,37,11,019,11,01,31,26,31,11,01,31,28,04,32,21,31,2111,31,08,12,02,11,01,33,256,31,01,11,03,12,01,11,01,12,02,11,01,11,02,32,02,11,010,11,31,25,31,11,017,13,08,11,09,11,01,32,26,31,01,12,32,2111,32,22,32,27,33,02,11,011,11,01,32,27,35,03,35,236,11,013,31,24,32,11,02,11,013,12,02,31,11,039,31,29,31,11,01,11,36,295,37,22,31,01,11,04,33,05,11,021,12,01,32,01,31,01,11,011,11,31,234,31,01,13,010,26,33,22,31,11,047,31,01,11,05,11,05,31,23,12,04,31,294,32,01,11,07,12,02,11,01,32,21,31,11,026,13,01,12,02,11,015,11,01,32,234,32,02,13,01,12,01,213,01,12,041,11,01,32,21,08,11,32,01,32,02,13,31,295,31,01,11,013,11,24,31,11,023,13,028,11,01,31,238,31,11,01,31,217,31,11,037,11,31,21,31,11,01,31,21,31,03,11,02,31,22,35,21,31,297,34,02,11,010,31,21,01,11,059,32,237,32,210,36,02,31,038,13,01,11,01,32,01,31,01,32,2113,11,32,09,11,01,11,062,11,01,32,244,34,13,01,11,34,041,11,01,33,2115,31,01,31,11,077,247,31,21,31,06,13,043,211,32,212,31,02,31,21,31,01,31,27,31,02,11,01,31,269,31,11,03,11,077,244,31,01,12,01,12,044,11,03,12,01,24,33,03,21,31,02,32,28,31,11,02,13,01,11,01,32,24,04,31,265,34,11,03,11,32,01,12,074,241,32,01,11,051,27,31,06,31,01,11,04,12,31,22,33,21,04,33,01,13,31,25,31,11,01,11,01,31,254,32,25,31,11,07,11,31,12,076,11,31,239,31,11,053,31,26,31,02,11,08,12,31,11,01,11,31,21,31,11,01,31,218,11,03,253,31,12,01,12,31,21,31,11,09,31,11,079,31,237,31,055,12,01,31,03,12,06,32,02,12,04,11,02,13,01,31,02,32,01,211,31,03,254,31,01,11,02,11,31,21,31,03,13,32,21,084,31,232,31,01,11,056,11,01,21,33,29,31,11,017,11,02,269,31,11,07,11,01,32,01,31,01,12,086,21,32,226,01,11,058,31,217,33,12,01,11,33,01,18,272,11,08,11,092,11,31,01,31,212,32,03,31,01,13,02,21,058,11,01,223,32,223,01,11,31,258,0103,11,31,01,11,31,210,11,011,31,21,11,055,31,238,02,31,29,31,13,34,252,0108,12,31,27,31,016,11,052,241,12,31,210,31,12,01,31,14,01,13,01,31,241,31,13,0106,11,03,26,31,010,13,03,11,050,31,242,31,03,215,31,09,31,21,31,212,34,213,31,21,33,02,11,071,11,042,31,26,06,22,07,11,02,12,02,11,044,31,244,03,214,010,12,01,29,32,11,05,210,31,12,31,11,0120,11,02,31,23,34,22,31,08,11,02,12,01,12,01,12,01,11,039,244,31,11,01,11,31,28,32,01,11,012,11,27,31,01,11,08,21,31,27,31,13,09,31,0116,14,01,23,34,11,017,11,031,11,04,11,31,245,31,01,11,01,25,31,01,11,018,25,11,010,12,02,28,010,31,0123,12,01,31,22,010,12,044,31,248,01,31,01,13,021,31,23,31,010,11,03,11,21,01,32,25,11,012,11,0124,21,08,31,21,01,32,02,11,03,11,036,11,01,31,247,03,33,021,31,22,015,11,31,04,31,21,01,11,08,11,01,11,31,0129,31,02,32,23,31,28,31,039,31,251,31,021,11,01,11,01,31,013,11,31,04,11,09,12,05,31,11,0130,215,31,03,11,034,11,01,31,22,33,21,31,02,12,31,235,31,025,11,012,13,02,31,012,31,01,11,01,11,01,11,01,11,0129,31,221,036,11,011,13,230,31,042,31,01,11,31,21,11,06,11,01,23,11,0134,11,31,223,11,048,11,228,31,11,043,11,31,21,33,03,11,32,25,02,14,02,31,11,0115,12,07,11,224,31,21,32,01,11,045,226,31,11,046,11,01,22,31,12,02,31,25,06,12,03,11,01,31,02,13,06,11,0109,11,231,33,01,11,039,11,31,223,11,049,12,31,22,01,11,02,11,06,31,01,31,11,02,14,01,11,31,01,31,24,31,01,11,06,11,0105,236,32,039,31,221,31,053,11,03,15,04,14,08,12,01,11,31,25,31,01,12,01,11,02,11,0103,11,31,235,31,039,11,222,056,13,03,19,01,11,03,11,07,33,11,01,31,02,11,04,15,0100,31,233,042,31,221,066,12,01,12,04,13,012,13,07,12,0101,31,230,31,11,041,11,31,221,31,071,11,03,31,22,32,04,21,0119,31,228,043,31,222,31,03,11,01,31,21,31,061,11,31,21,32,25,01,11,02,11,22,31,11,017,12,08,11,089,11,01,31,225,11,041,11,220,31,01,11,03,11,24,11,059,11,31,212,33,23,31,018,11,08,11,092,224,044,11,31,217,11,06,11,23,31,055,12,02,31,221,31,01,11,012,11,0103,31,220,33,046,11,217,07,31,22,31,054,11,31,228,31,013,11,0102,31,217,31,01,11,050,31,214,31,01,11,06,11,32,11,055,231,31,11,0112,11,218,053,11,31,213,11,066,11,232,31,0113,217,055,11,31,210,31,11,068,11,231,31,0112,31,215,31,11,056,11,28,31,072,31,26,33,02,12,01,31,214,31,11,0111,11,211,34,11,060,31,04,12,074,32,01,14,010,32,29,31,11,017,11,093,11,31,212,0162,11,02,26,32,11,018,11,02,12,089,11,29,03,11,0165,12,01,11,01,12,022,21,01,11,090,31,25,31,0174,11,32,019,11,31,01,11,093,31,24,32,11,0174,11,01,11,015,11,01,32,01,11,093,25,31,0196,31,01,11,094,31,25,31,0113,11,0179,31,24,31,11,05,13,0285,11,01,33,21,01,11,05,11,0289,12,02,11,0904,15,0291,11,01,31,01,14,090,14,036,14,05,13,0147,11,01,32,01,11,087,13,03,31,25,32,08,11,07,13,02,314,24,34,23,313,26,36,02,11,02,11,02,11,0108,13,32,02,23,31,01,11,044,11,02,11,04,111,01,12,01,19,01,32,04,31,222,32,01,12,02,32,261,32,21,34,01,16,074,12,04,17,06,11,02,11,03,33,01,25,038,12,01,31,21,32,21,32,21,33,255,03,31,279,32,037,11,01,11,02,13,08,32,02,31,01,31,01,31,01,31,03,16,02,31,212,33,23,32,29,32,01,11,032,13,01,31,2148,31,02,11,029,11,03,12,02,33,257,31,01,31,03,13,015,12,09,11,03,34,2156,31,11,01,13,022,11,01,12,02,11,04,32,255,35,12,02,11,01,11,01,12,02,12,06,11,01,31,24,31,05,11,03,35,2155,31,01,14,025,12,03,12,01,33,262,33,21,34,04,11,03,12,06,13,01,36,2163,02,12,015,12,08,37,279,33,2188,35,05,2600
    """

    private static let dayIndices = decode(dayRLE)
    private static let nightIndices = decode(nightRLE)

    /// Fibonacci 球面均匀采样点；经度在采样时固定，字符随采样点携带大陆信息一起旋转。
    struct SurfaceSample {
        let x: Double
        let y: Double
        let z: Double
        let longitude: Double
    }

    static let samples: [SurfaceSample] = makeSamples(count: 900)

    static func sample(longitude: Double, sineLatitude: Double) -> (day: Double, night: Double) {
        let latitude = asin(min(1, max(-1, sineLatitude)))
        let u = (longitude / (2 * .pi) + 0.5) * Double(width) - 0.5
        let v = (0.5 - latitude / .pi) * Double(height - 1)
        return (bilinear(dayIndices, u: u, v: v), bilinear(nightIndices, u: u, v: v))
    }

    private static func bilinear(_ grid: [Double], u: Double, v: Double) -> Double {
        guard grid.count == width * height else { return 0 }
        var x = u.truncatingRemainder(dividingBy: Double(width))
        if x < 0 { x += Double(width) }
        let y = min(Double(height - 1), max(0, v))
        let x0 = Int(x.rounded(.down)) % width
        let x1 = (x0 + 1) % width
        let y0 = Int(y.rounded(.down))
        let y1 = min(height - 1, y0 + 1)
        let tx = x - x.rounded(.down)
        let ty = y - y.rounded(.down)
        let top = grid[y0 * width + x0] * (1 - tx) + grid[y0 * width + x1] * tx
        let bottom = grid[y1 * width + x0] * (1 - tx) + grid[y1 * width + x1] * tx
        return top * (1 - ty) + bottom * ty
    }

    private static func makeSamples(count: Int) -> [SurfaceSample] {
        let goldenAngle = Double.pi * (3 - (5.0).squareRoot())
        return (0 ..< count).map { index in
            let y = 1 - 2 * (Double(index) + 0.5) / Double(count)
            let ring = (1 - y * y).squareRoot()
            let phi = Double(index) * goldenAngle
            let x = cos(phi) * ring
            let z = sin(phi) * ring
            return SurfaceSample(x: x, y: y, z: z, longitude: atan2(x, z))
        }
    }

    private static func decode(_ rle: String) -> [Double] {
        let digits = Array("0123456789ABCDEFGH")
        var lookup: [Character: Double] = [:]
        for (offset, digit) in digits.enumerated() { lookup[digit] = Double(offset) }
        var result: [Double] = []
        result.reserveCapacity(width * height)
        for run in rle.split(separator: ",") {
            guard let symbol = run.first,
                  let value = lookup[symbol],
                  let count = Int(run.dropFirst()) else { continue }
            result.append(contentsOf: repeatElement(value, count: count))
        }
        return result
    }
}
