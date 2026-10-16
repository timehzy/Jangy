import SwiftUI
import JangyCore

/// 消歧：SwiftUI（iOS 26）也有 `DragSession`（系统拖放会话）。本 App 的拖拽会话一律指 JangyCore 的。
/// （模块级别名，遮蔽 SwiftUI 的同名类型；App 不用 SwiftUI 的拖放会话 API。）
typealias DragSession = JangyCore.DragSession

/// 车道呈现上下文：呈现器只读这里的东西（plan / 视口 / 解析器 / 缩略图器 / 拖动会话）。
struct LaneContext {
    let plan: EditPlan
    let viewport: TimelineViewportState
    let resolver: AssetResolver
    let thumbnailer: TimelineThumbnailer
    /// 当前拖拽会话（高频，来自 L0 的手势态）。车道据此对**被拖元素**施加瞬态位移/缩放——
    /// 只改局部 SwiftUI，plan 不动（公约 §6.5）。非拖动态恒 nil。
    var drag: DragSession? = nil
}

/// 拖动中元素的瞬态几何（点）：move 的偏移、trim 的左右边缘增量。
/// 选中框/手柄（容器层）与车道内容都用它换算（同源），保证图层与手势一致；plan 不动。
struct TransientGeometry {
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    /// 左边缘位移（点，右正）：>0 = 前沿内收（trim 起手侧）。
    var leadingDelta: CGFloat = 0
    /// 右边缘位移（点，右正）：>0 = 后沿外扩（trim 收尾侧）。
    var trailingDelta: CGFloat = 0
    /// 是否处于「移动浮起」态（决定放大 + 阴影；trim 不是浮起）。
    var isLifted = false

    /// 浮起放大系数（唯一来源；容器层与车道共用）。
    static let liftScale: CGFloat = 1.06

    static func make(elementID: UUID, drag: DragSession?) -> TransientGeometry {
        guard let drag else { return TransientGeometry() }
        switch drag.kind {
        case .moveElement(let id, _) where id == elementID:
            // 浮起 = 「元素已离开原位」：位移非零才算真的在拖。手势层的起手阈值保证未越过阈值时
            // 给不出非零位移，故长按不放（位移恒 0）不浮起——否则「只想点一下」也会弹一下。
            return TransientGeometry(offsetX: drag.translation.width, offsetY: drag.translation.height,
                                     isLifted: drag.translation != .zero)
        case .trim(let id, let edge) where id == elementID:
            var geometry = TransientGeometry()
            if edge == .leading { geometry.leadingDelta = drag.translation.width }
            else { geometry.trailingDelta = drag.translation.width }
            return geometry
        default:
            return TransientGeometry()
        }
    }
}

/// 浮起的**几何**：绕自身中心放大 + 跟随手指的位移。只读瞬态几何，plan 不动。
///
/// **缩放必须在定位之前**：`scaleEffect` 的锚点是**被修饰视图自身 frame 的中心**，而 `offset`
/// 只是渲染位移、不改 frame——写成 `offset(x: contentX…).scaleEffect()` 时定位量会一起被缩放，
/// 元素按自己在内容坐标里的位置成比例横移（`contentX` 越大偏得越多，浮起瞬间整段横跳）。
/// **容器层（选中框 / 手柄）与车道内容块都走这一条**，两处的缩放中心与顺序不可能再对不上。
struct LiftTransformModifier: ViewModifier {
    let geometry: TransientGeometry
    /// 元素块在内容坐标里的 x（`contentX(forTime:)` + 前沿瞬态位移）。
    let x: CGFloat
    /// 内容块在车道内的竖直对齐偏移（如字幕条居中）。
    var y: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .scaleEffect(geometry.isLifted ? TransientGeometry.liftScale : 1)
            .offset(x: x + geometry.offsetX, y: y + geometry.offsetY)
    }
}

/// 车道元素块 = 浮起几何（`LiftTransformModifier`）+ 阴影 + 层级。内容块**一律不自定位**。
///
/// **修饰链恒定**：非浮起时各参数取中性值，**不得**写成 `if isLifted { … } else { … }`——
/// `@ViewBuilder` 的 if/else 是两个分支，切换分支 = 被包内容换了结构位置 = SwiftUI 拆掉旧子树
/// 重建新子树，里面的 `@State`（如胶片条的帧缓存）跟着清空。浮起 / 落下各来一次，缩略图就闪两下灰底。
struct LaneElementModifier: ViewModifier {
    let geometry: TransientGeometry
    let x: CGFloat
    var y: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .modifier(LiftTransformModifier(geometry: geometry, x: x, y: y))
            .shadow(color: .black.opacity(geometry.isLifted ? 0.4 : 0),
                    radius: geometry.isLifted ? 6 : 0)
            .zIndex(geometry.isLifted ? 1 : 0)
    }
}

/// 一类轨的 L0 呈现片（与 L2 `Features/<Name>/<Name>Feature.swift`、L3 `<Name>Engine.swift` 同 kind 的三片之一）。
protocol TrackLaneProvider {
    static var kind: TrackKind { get }
    /// 轨道头图标（SF Symbol）。放这里是为了让轨道头也不 switch kind。
    static var icon: String { get }
    @MainActor static func makeLane(track: PlanTrack, context: LaneContext) -> AnyView
}

/// 车道呈现器注册表 —— L0 侧唯一注册点。加一类轨 = 这里加一行 + 新增 `Features/<Name>/<Name>Lane.swift`。
/// **TrackLaneView 不得 switch 具体轨类型**（公约 §1）；不认识 kind 时回落通用车道。
enum TrackLaneRegistry {
    static let providers: [any TrackLaneProvider.Type] = [
        VideoLaneProvider.self,
        CaptionLaneProvider.self,
    ]

    static func provider(for kind: TrackKind) -> (any TrackLaneProvider.Type)? {
        providers.first { $0.kind == kind }
    }

    /// 轨道头图标：命中的呈现片给图标，未知 kind 回落通用符号（同样不 switch kind）。
    static func icon(for kind: TrackKind) -> String {
        provider(for: kind)?.icon ?? "square.stack.3d.up"
    }
}

/// 车道 / 轨道头共用的尺寸常量与几何（同一行内高度对齐、元素定宽都靠它）。
enum LaneMetrics {
    static let height: CGFloat = 56
    static let cornerRadius: CGFloat = 4

    /// 元素/车道块宽（点）= 时长 × px/s；下限 1 避免零宽或负宽。
    static func width(forDuration duration: TimeInterval, viewport: TimelineViewportState) -> CGFloat {
        max(1, CGFloat(duration) * viewport.pointsPerSecond)
    }
}
