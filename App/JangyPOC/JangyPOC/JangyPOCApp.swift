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
            let draftStore = DraftStore(directory: support)
            // 草稿恢复：有合法草稿则接着上次编辑；损坏/版本过新回落样例工程并告知原因
            var initial = SamplePlan.make()
            var restoreNotice: String?
            do {
                if let draft = try draftStore.load() {
                    initial = draft
                }
            } catch {
                restoreNotice = "草稿恢复失败（\(error.localizedDescription)），已回到样例工程"
            }
            let store = EditStore(initial: initial)
            _model = State(initialValue: AppModel(store: store, resolver: resolver,
                                                  draftStore: draftStore, restoreNotice: restoreNotice))
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
