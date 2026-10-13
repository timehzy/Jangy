import SwiftUI
import JangyCore

/// 导出面板：点「导出」后先弹出的配置确认层，确认后才真正开始导出。
/// 扩展方式：新导出选项加进 `ExportOptions`（JangyCore 状态层），此处追加对应控件即可。
struct ExportPanel: View {
    /// 面板内编辑的配置副本；确认时一次性回传，不直接改外部状态
    @State private var options: ExportOptions = .default
    let onConfirm: (ExportOptions) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("HDR 直通", isOn: $options.hdrPassthrough)
                } footer: {
                    Text("开启：保留 HDR（BT.2020 + HLG），画质无损直通。\n关闭：导出 SDR（BT.709，H.264），分享到不支持 HDR 的平台不会发灰。")
                }
            }
            .navigationTitle("导出设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始导出") {
                        dismiss()
                        onConfirm(options)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.height(300)])
    }
}
