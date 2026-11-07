import SwiftUI
import AppKit

/// Top right: the video with the current title drawn over it.
struct VideoPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var doc: SubtitleDocument
    @ObservedObject var clock: PlayheadClock

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Picture", color: Theme.periwinkle) {
                if let url = model.videoURL {
                    Text(url.lastPathComponent)
                        .font(Theme.label(11, .medium))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            ZStack(alignment: .bottom) {
                Color.black
                if model.hasMedia {
                    EngineSurface(engine: model.engine)
                } else {
                    VStack(spacing: 10) {
                        Group {
                        if let name = model.loadingName {
                            ProgressView().controlSize(.small)
                            ConsoleLabel(text: model.isDownloadingFromICloud ? "Waiting for iCloud" : "Opening",
                                         color: Theme.teal, size: 12)
                            Text(name)
                            if model.isDownloadingFromICloud {
                                Button("Cancel") { model.cancelICloudWait() }
                                    .buttonStyle(.link)
                            }
                        } else {
                            ConsoleLabel(text: "Awaiting picture", color: Theme.periwinkle, size: 12)
                            Text("Drop a video here, or add one with ⌥⌘N")
                        }
                        }
                            .font(Theme.label(13, .regular))
                            .foregroundStyle(Theme.textDim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let text = overlayText, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 22, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2, x: 0, y: 1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.55)))
                        .padding(.bottom, 28)
                        .padding(.horizontal, 40)
                        .allowsHitTesting(false)
                } else if overlayText != nil || model.isSpotting {
                    // A title with no text yet (or one being spotted): a clear glass placeholder.
                    GlassPlaceholder()
                        .frame(width: 280, height: 56)
                        .overlay(alignment: .topTrailing) {
                            if let timer = model.spotTimer() {
                                SpotTimerPill(text: timer.text, status: timer.status).padding(6)
                            }
                        }
                        .padding(.bottom, 28)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding([.horizontal, .bottom], 10)
        }
        .background(Theme.panel)
    }

    /// While playing: whatever is on screen. While paused: the selected title if
    /// the playhead is inside it (so you see it as you type), else what's on screen.
    private var overlayText: String? {
        let t = clock.time
        if !clock.isPlaying, let sel = doc.selected, sel.start <= t, t < sel.end { return sel.text }
        return doc.active(at: t)?.text
    }
}

/// Hosts whatever view the playback engine provides.
struct EngineSurface: NSViewRepresentable {
    let engine: PlaybackEngine

    func makeNSView(context: Context) -> NSView {
        engine.makeVideoView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Clear Mac glass for an empty title: Liquid Glass on macOS 26, a thin material before.
private struct GlassPlaceholder: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if #available(macOS 26, *) {
            Color.clear
                .glassEffect(.clear, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        } else {
            shape.fill(.ultraThinMaterial)
                .opacity(0.55)
                .overlay(shape.stroke(Color.white.opacity(0.22), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
    }
}
