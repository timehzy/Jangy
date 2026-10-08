import AVKit
import POCCore
import SwiftUI

/// 预览：VideoPlayer + SwiftUI 字幕叠加层。
/// Kadr overlay（烧录字幕）不进入预览（AVFoundation 限制，export-only），故用原生 Text 按播放时间叠加。
struct PreviewView: View {
    let player: PlayerController

    var body: some View {
        ZStack(alignment: .bottom) {
            if let avPlayer = player.player {
                VideoPlayer(player: avPlayer)
            } else {
                Color.black.overlay(Text("加载预览…").foregroundStyle(.white))
            }
            if let cue = player.currentCue {
                Text(cue.text)
                    .font(.title2).bold()
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: .rect(cornerRadius: 8))
                    .foregroundStyle(.white)
                    .padding(.bottom, 40)
            }
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 12))
        .padding()
    }
}
