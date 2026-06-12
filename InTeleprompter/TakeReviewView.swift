import AVKit
import SwiftUI

/// Full-screen playback of the most recent take, straight from the local
/// review copy — no round trip through the Photos library.
struct TakeReviewView: View {
    let take: Take

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .padding(16)
            .accessibilityLabel("Close take review")
        }
        .onAppear {
            let player = AVPlayer(url: take.url)
            self.player = player
            player.play()
        }
        .onDisappear {
            player?.pause()
        }
    }
}

/// The small bottom-corner button that opens the last take for review.
struct TakeThumbnailButton: View {
    let take: Take
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottom) {
                if let thumbnail = take.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.black.opacity(0.55)
                }

                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(radius: 3)
                    .frame(maxHeight: .infinity)

                Text(take.durationText)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity)
                    .background(.black.opacity(0.55))
            }
            .frame(width: 58, height: 78)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.white.opacity(0.8), lineWidth: 1.5)
            )
        }
        .accessibilityLabel("Review last take, \(take.durationText)")
    }
}
