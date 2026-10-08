import Foundation
import Kadr

/// headless 导出的进度事件流。CLI 逐行 JSON 化输出；App 驱动进度条。
public enum ExportEvent: Sendable, Equatable {
    case progress(Double)
    /// durationMs 含 composition 构建时间（从 makeComposition 前起算），非纯编码耗时。
    case done(url: URL, durationMs: Int)
}

public enum ExportRunner {

    public static func export(plan: EditPlan, resolver: AssetResolver, to output: URL) -> AsyncThrowingStream<ExportEvent, Error> {
        AsyncThrowingStream { continuation in
            // exporter 在 Task 内、makeComposition 之后才创建；共享盒子让 onTermination
            // 也能取消 Kadr 导出（仅 cancel Task 时 Exporter 仍会在后台写盘）。
            let exporterBox = ExporterBox()
            let task = Task {
                do {
                    let start = Date()
                    let video = try await EngineBridge.makeComposition(from: plan, resolver: resolver)
                    let exporter = video.exporter(to: output)
                    exporterBox.exporter = exporter
                    for try await progress in exporter.run() {
                        continuation.yield(.progress(progress.fractionCompleted))
                    }
                    // 防静默 passthrough：Kadr 兼容性检查失败时会"成功"地产出
                    // 未渲染的码流拷贝（详见 ExportVerifier 注释）——交付前硬校验。
                    try await ExportVerifier.verify(output: output, preset: plan.preset)
                    continuation.yield(.done(url: output, durationMs: Int(Date().timeIntervalSince(start) * 1000)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                exporterBox.exporter?.cancel()
            }
        }
    }
}

/// 导出 Task（写入）与 onTermination（读取并 cancel）之间共享的 exporter 盒子。
/// 唯一竞态是"终止早于 exporter 创建"——此时 Kadr 导出尚未开始，task.cancel() 已足够。
private final class ExporterBox: @unchecked Sendable {
    var exporter: Kadr.Exporter?
}
