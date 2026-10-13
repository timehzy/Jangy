import SwiftUI
import JangyCore

@main
@MainActor
struct JangyApp: App {
    @State private var model: AppModel

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jangy", isDirectory: true)
        // 启动只做廉价装配。目录预先建好，DraftStore/Resolver 即可正常工作。
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let resolver = AssetResolver(directory: support)
        let draftStore = DraftStore(directory: support)
        // 草稿恢复：有合法草稿则接着上次编辑；无草稿/损坏/版本过新从空时间线起步并告知原因
        var initial = EditPlan(clips: [])
        var restoreNotice: String?
        do {
            if let draft = try draftStore.load() {
                initial = draft
            }
        } catch {
            restoreNotice = "草稿恢复失败（\(error.localizedDescription)），已回到空草稿"
        }
        let store = EditStore(initial: initial)
        _model = State(initialValue: AppModel(store: store, resolver: resolver,
                                              draftStore: draftStore, restoreNotice: restoreNotice))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
