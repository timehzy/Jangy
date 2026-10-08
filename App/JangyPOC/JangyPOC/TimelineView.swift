import SwiftUI
import POCCore

/// 时间线：每行一个片段，提供 POC 五类操作中的四类（裁剪/变速/转场/删除）。
struct TimelineView: View {
    let model: AppModel

    var body: some View {
        List {
            ForEach(Array(model.store.plan.clips.enumerated()), id: \.element.id) { index, clip in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(index + 1). \(clip.source.fileName)  [\(clip.range.lowerBound, format: .number.precision(.fractionLength(1)))–\(clip.range.upperBound, format: .number.precision(.fractionLength(1)))s]  \(clip.speed.rate, format: .number.precision(.fractionLength(2)))x")
                        .font(.callout)
                    HStack {
                        Button("裁剪") { toggleTrim(index) }
                        Button("变速") { cycleSpeed(index) }
                        if index < model.store.plan.clips.count - 1 {
                            Button(clip.transitionAfter == nil ? "加转场" : "去转场") { toggleTransition(index) }
                        }
                        Button("删除", role: .destructive) { delete(index) }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func toggleTrim(_ index: Int) {
        model.edit {
            let clip = $0.clips[index]
            $0.clips[index].range = clip.range.lowerBound == 0 ? 0.5...2.5 : 0...3
        }
    }

    private func cycleSpeed(_ index: Int) {
        model.edit {
            let current = $0.clips[index].speed.rate
            let next: Double = current == 1.0 ? 0.5 : (current == 0.5 ? 2.0 : 1.0)
            $0.clips[index].speed = .flat(next)
        }
    }

    private func toggleTransition(_ index: Int) {
        model.edit {
            $0.clips[index].transitionAfter = $0.clips[index].transitionAfter == nil ? .dissolve(duration: 0.5) : nil
        }
    }

    private func delete(_ index: Int) {
        model.edit {
            $0.clips.remove(at: index)
            // 删除后若新的末位片段挂着转场，一并清掉（否则校验失败）
            if let last = $0.clips.indices.last, $0.clips[last].transitionAfter != nil {
                $0.clips[last].transitionAfter = nil
            }
        }
    }
}
