import SwiftUI
import JangyCore

@main
@MainActor
struct JangyApp: App {
    @State private var projectListModel: ProjectListModel
    @State private var libraryModel: LibraryModel

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jangy", isDirectory: true)
        // 启动只做廉价装配：目录预建 + 旧布局迁移（幂等）
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let projectStore = ProjectStore(root: support)
        try? projectStore.migrateLegacyLayoutIfNeeded()
        let library = AssetLibrary(root: support)
        let resolver = library.resolver
        _projectListModel = State(initialValue: ProjectListModel(
            projectStore: projectStore, library: library, resolver: resolver))
        _libraryModel = State(initialValue: LibraryModel(
            library: library, resolver: resolver, projectStore: projectStore))
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ProjectListView(model: projectListModel, libraryModel: libraryModel)
            }
        }
    }
}
