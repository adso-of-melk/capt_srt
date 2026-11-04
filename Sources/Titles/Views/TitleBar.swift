import SwiftUI

/// The strip above the waveform: timecode, transport, spotting mode, zoom and scale.
struct TitleBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clock: PlayheadClock
    @ObservedObject var audio: AudioStore

    var body: some View {
        HStack(spacing: 14) {
            HomeButton { model.goHome() }

            divider

            // Timecode readout
            HStack(spacing: 8) {
                Capsule().fill(Theme.amber).frame(width: 34, height: 22)
                    .overlay(
                        Image(systemName: clock.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.background)
                    )
                    .onTapGesture { model.togglePlay() }
                    .help("Play / pause (Shift+Space)")
                Text(Timecode.frames(clock.time, fps: model.engine.frameRate))
                    .font(Theme.mono(17, .semibold))
                    .foregroundStyle(Theme.peach)
                    .monospacedDigit()
                Text("/ " + Timecode.frames(model.engine.duration, fps: model.engine.frameRate))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textFaint)
            }

            divider

            // Spotting mode
            HStack(spacing: 6) {
                ConsoleLabel(text: "Spot", size: 9)
                Picker("", selection: $model.spotMode) {
                    ForEach(SpotMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 96)
                .help("Hold: hold ↓ while a line is spoken. Tap: ↓ ends this and starts the next, ↑ ends.")
                if model.isSpotting {
                    Circle().fill(Theme.red).frame(width: 8, height: 8)
                }
            }

            // Speed
            HStack(spacing: 6) {
                ConsoleLabel(text: "Speed", size: 9)
                Picker("", selection: $model.playbackRate) {
                    Text("0.5×").tag(Float(0.5))
                    Text("0.75×").tag(Float(0.75))
                    Text("1×").tag(Float(1))
                    Text("1.25×").tag(Float(1.25))
                }
                .labelsHidden()
                .frame(width: 70)
            }

            Spacer(minLength: 8)

            if let name = model.loadingName {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    ConsoleLabel(text: model.isDownloadingFromICloud ? "Downloading from iCloud" : "Opening",
                                 color: Theme.teal, size: 9)
                    Text(name)
                        .font(Theme.label(11, .medium))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else if let msg = model.statusMessage {
                Text(msg)
                    .font(Theme.label(11, .medium))
                    .foregroundStyle(Theme.peach)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if audio.isLoading {
                HStack(spacing: 6) {
                    ConsoleLabel(text: "Reading audio", color: Theme.teal, size: 9)
                    ProgressView(value: audio.progress)
                        .progressViewStyle(.linear)
                        .tint(Theme.teal)
                        .frame(width: 80)
                }
            } else if let err = audio.errorMessage {
                Text(err).font(Theme.label(11, .medium)).foregroundStyle(Theme.red).lineLimit(1)
            }

            divider

            // Zoom
            HStack(spacing: 6) {
                ConsoleLabel(text: "Zoom", size: 9)
                Slider(value: zoomBinding, in: 0...1)
                    .frame(width: 90)
                    .tint(Theme.periwinkle)
            }
            // Waveform scale
            HStack(spacing: 6) {
                ConsoleLabel(text: "Scale", size: 9)
                Slider(value: $model.waveGain, in: 0.5...8)
                    .frame(width: 80)
                    .tint(Theme.teal)
                Toggle(isOn: $model.dbScale) {
                    Text("dB").font(Theme.label(10, .bold))
                }
                .toggleStyle(.button)
                .help("Show loudness in decibels, so quiet speech is visible next to loud sounds")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Theme.panelRaised)
        .overlay(alignment: .top) { Rectangle().fill(Theme.rule).frame(height: 1) }
    }

    private var divider: some View {
        Rectangle().fill(Theme.rule).frame(width: 1, height: 20)
    }

    /// Log mapping: 0…1 slider → 8…1600 pixels per second.
    private var zoomBinding: Binding<Double> {
        Binding(
            get: { (log(model.pixelsPerSecond) - log(8)) / (log(1600) - log(8)) },
            set: { model.pixelsPerSecond = exp(log(8) + $0 * (log(1600) - log(8))) }
        )
    }
}

/// Leaves the film for the home screen, asking to save unsaved changes first.
private struct HomeButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                Text("HOME").font(Theme.label(10, .bold)).tracking(1.4)
            }
            .foregroundStyle(hover ? Theme.background : Theme.teal)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(hover ? Theme.teal : Theme.teal.opacity(0.12)))
            .overlay(Capsule().stroke(Theme.teal.opacity(0.4), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Back to the home screen to choose another film (⇧⌘H)")
    }
}
