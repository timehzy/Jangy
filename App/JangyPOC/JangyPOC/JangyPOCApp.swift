import SwiftUI
import POCCore

@main
@MainActor
struct JangyPOCApp: App {
    @State private var model: AppModel

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JangyPOC", isDirectory: true)
        do {
            // POC 取舍：首次启动同步合成素材会阻塞主线程数秒（幂等，仅首次）；正式版应移出启动关键路径。
            let resolver = try AssetSynthesizer.synthesize(into: support)
            let store = EditStore(initial: SamplePlan.make())
            _model = State(initialValue: AppModel(store: store, resolver: resolver))
        } catch {
            preconditionFailure("测试素材合成失败: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
