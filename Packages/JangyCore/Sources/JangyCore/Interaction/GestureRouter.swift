import Foundation

/// 手势 → 会话的路由：按下时按命中对象决定开哪种 `DragSession`。
/// 纯函数——**几何命中由 L0 做**（它才有布局），这里只把「命中了什么」翻成会话。
/// 不认识具体轨类型（公约 §1）：只按「元素 / 手柄 / 轨道头」这类结构信息路由。
public enum GestureRouter {

    /// 命中对象（L0 的几何命中结果）。
    public enum Hit: Equatable, Sendable {
        case trimHandle(elementID: UUID, edge: DragSession.Edge)
        case element(id: UUID)
        case trackCap(trackID: UUID)
        case empty
    }

    /// 长按拾起后的会话：元素 → 移动，轨道头 → 重排，空处 → nil（那是滚动，不是编辑）。
    public static func liftSession(for hit: Hit, plan: EditPlan) -> DragSession? {
        switch hit {
        case .element(let id):
            guard let track = plan.tracks.first(where: { $0.elements.contains { $0.id == id } })
            else { return nil }
            return DragSession(kind: .moveElement(elementID: id, fromTrackID: track.id))
        case .trackCap(let trackID):
            return DragSession(kind: .reorderTrack(trackID: trackID))
        case .trimHandle, .empty:
            return nil
        }
    }

    /// 直接拖 trim 手柄的会话。
    public static func trimSession(for hit: Hit) -> DragSession? {
        guard case .trimHandle(let elementID, let edge) = hit else { return nil }
        return DragSession(kind: .trim(elementID: elementID, edge: edge))
    }
}
