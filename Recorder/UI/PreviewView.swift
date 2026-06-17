import AVFoundation
import AVKit
import SwiftUI

struct PreviewView: View {
    let url: URL

    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.headline)

            VideoPlayer(player: player)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .onAppear {
            player = AVPlayer(url: url)
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
