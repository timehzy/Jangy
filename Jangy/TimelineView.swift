import SwiftUI
import JangyCore

/// 时间线（简化版）：水平排布、每段固定宽度。点片段弹操作（裁剪/变速/转场/删除）。
/// 「＋」浮动在可见区域右缘（不随轨道滚动），点击进素材库追加素材。
/// 精细化（缩放/拖拽排序/可变宽度）留给时间线专项。
struct TimelineView: View {
    let model: AppModel
    var onAdd: () -> Void

    @State private var actionIndex: Int?

    /// 主轨元素（v4：片段在主轨元素里；删除会留下等长 gap 元素）。
    private var primaryElements: [PlanElement] {
        model.store.plan.primaryTrack?.elements ?? []
    }

    /// 主轨第 index 个元素解出的 clip（gap / 越界 → nil）。
    private func clip(_ index: Int) -> PlanClip? {
        guard primaryElements.indices.contains(index),
              case .content(let payload) = primaryElements[index].content else { return nil }
        return payload.value as? PlanClip
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 总时长用实测口径（dissolve 重叠扣除），与导出产物时长一致
            Text("总时长 \(model.store.plan.renderedDuration.formatted(.number.precision(.fractionLength(1))))s")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            ZStack(alignment: .trailing) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(primaryElements.enumerated()), id: \.element.id) { index, element in
                            elementBlock(index: index, element: element)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.trailing, 56)  // 给浮动＋让位
                }

                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.body.bold())
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor, in: Circle())
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                }
                .padding(.trailing, 8)
                .buttonStyle(.plain)
                // Agent 运行中禁用：quick-add 上轨会并入 Agent 撤销组
                .disabled(model.agent.isRunning)
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog("片段 \((actionIndex ?? 0) + 1)", isPresented: actionBinding, titleVisibility: .visible) {
            Button("裁剪") { if let i = actionIndex { toggleTrim(i) } }
            Button("变速") { if let i = actionIndex { cycleSpeed(i) } }
            if let i = actionIndex, i < primaryElements.count - 1, let c = clip(i) {
                Button(c.transitionAfter == nil ? "加转场" : "去转场") { toggleTransition(i) }
            }
            Button("删除", role: .destructive) { if let i = actionIndex { delete(i) } }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func elementBlock(index: Int, element: PlanElement) -> some View {
        if let clip = clip(index) {
            clipBlock(index: index, clip: clip)
        } else {
            // 删除留下的空档：占位显示，保留时长
            Text("空档\n\(element.duration.formatted(.number.precision(.fractionLength(1))))s")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(width: 72, height: 56)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func clipBlock(index: Int, clip: PlanClip) -> some View {
        Button { actionIndex = index } label: {
            VStack(spacing: 2) {
                Text(displayName(for: clip))
                    .font(.caption2)
                    .lineLimit(1)
                Text("\(clip.outputDuration.formatted(.number.precision(.fractionLength(1))))s · \(clip.speed.rate.formatted(.number.precision(.fractionLength(2))))x")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if clip.transitionAfter != nil {
                    Text("⇄ 转场").font(.caption2).foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 72, height: 56)
            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        // Agent 运行中禁用：分组期间手动编辑会并入 Agent 撤销组
        .disabled(model.agent.isRunning)
    }

    private var actionBinding: Binding<Bool> {
        Binding(get: { actionIndex != nil }, set: { if !$0 { actionIndex = nil } })
    }

    /// 片段标题：素材登记表里的 displayName；登记项缺失时兜底显示 ID 前 8 位
    private func displayName(for clip: PlanClip) -> String {
        model.store.plan.asset(withID: clip.assetID)?.displayName
            ?? String(clip.assetID.uuidString.prefix(8))
    }

    private func toggleTrim(_ index: Int) {
        model.edit { plan in
            guard let clip = clip(index) else { return }
            switch clip.source {
            case .video(let range):
                plan.updatePrimaryClip(at: index) { $0.source = .video(range.lowerBound == 0 ? 0.5...2.5 : 0...3) }
            case .still:
                plan.updatePrimaryClip(at: index) { $0.source = .still(duration: 2.0) }
            }
        }
    }

    private func cycleSpeed(_ index: Int) {
        model.edit { plan in
            guard let current = clip(index)?.speed.rate else { return }
            let next: Double = current == 1.0 ? 0.5 : (current == 0.5 ? 2.0 : 1.0)
            plan.updatePrimaryClip(at: index) { $0.speed = .flat(next) }
        }
    }

    private func toggleTransition(_ index: Int) {
        model.edit { plan in
            guard let clip = clip(index) else { return }
            plan.updatePrimaryClip(at: index) {
                $0.transitionAfter = clip.transitionAfter == nil ? .dissolve(duration: 0.5) : nil
            }
        }
    }

    private func delete(_ index: Int) {
        model.edit { plan in
            guard let ti = plan.tracks.firstIndex(where: { $0.id == plan.primaryTrackID }),
                  plan.tracks[ti].elements.indices.contains(index) else { return }
            let element = plan.tracks[ti].elements[index]
            plan.tracks[ti].elements[index] = PlanElement(id: element.id,
                                                          content: .gap(duration: element.duration))
        }
    }
}
