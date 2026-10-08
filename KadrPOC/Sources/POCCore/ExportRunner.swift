import Foundation
import Kadr

/// headless 导出的进度事件流。CLI 逐行 JSON 化输出；App 驱动进度条。
public enum ExportEvent: Sendable, Equatable {
    case progress(Double)
    case done(url: URL, durationMs: Int)
}

public enum ExportRunner {

    public static func export(plan: EditPlan, resolver: AssetResolver, to output: URL) -> AsyncThrowingStream<ExportEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let start = Date()
                    let video = try await EngineBridge.makeComposition(from: plan, resolver: resolver)
                    let exporter = video.exporter(to: output)
                    for try await progress in exporter.run() {
                        continuation.yield(.progress(progress.fractionCompleted))
                    }
                    continuation.yield(.done(url: output, durationMs: Int(Date().timeIntervalSince(start) * 1000)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
