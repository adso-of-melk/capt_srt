import SwiftUI

/// The strip above the waveform: timecode, transport, spotting mode, zoom and scale.
struct TitleBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clock: PlayheadClock
    @ObservedObject var audio: AudioStore

    var body: some View {
        HStack(spacing: 14) {
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
                if model.editingTimecode {
                    TimecodeEntry(model: model, time: clock.time)
                } else {
                    Text(model.tc(clock.time))
                        .lineLimit(1)
                        .fixedSize()
                        .font(Theme.mono(17, .semibold))
                        .foregroundStyle(Theme.peach)
                        .monospacedDigit()
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            if model.clock.isPlaying { model.togglePlay() }
                            model.editingTimecode = true
                        }
                        .help("Double-click to type a time to go to")
                }
                Text("/ " + model.tc(model.engine.duration))
                    .lineLimit(1)
                    .fixedSize()
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
                    ConsoleLabel(text: model.isDownloadingFromICloud ? "Waiting for iCloud" : "Opening",
                                 color: Theme.teal, size: 9)
                    Text(name)
                        .font(Theme.label(11, .medium))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if model.isDownloadingFromICloud {
                        Button("Cancel") { model.cancelICloudWait() }
                            .buttonStyle(.link)
                            .font(Theme.label(11, .semibold))
                    }
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

/// Go to a time: the readout becomes four fields (hours, minutes, seconds, frames or
/// milliseconds). Tab moves between them, and a field moves on by itself when it's full.
/// Return goes there; Esc or clicking away leaves the playhead where it was.
struct TimecodeEntry: View {
    @ObservedObject var model: AppModel
    let time: Double
    @State private var parts: [String] = ["", "", "", ""]
    @FocusState private var focus: Int?
    @State private var done = false

    private var usesMilliseconds: Bool { model.project?.settings.timecodeDisplay == .milliseconds }
    private func maxDigits(_ i: Int) -> Int { i == 3 && usesMilliseconds ? 3 : 2 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { i in
                TextField("", text: binding(i))
                    .textFieldStyle(.plain)
                    .font(Theme.mono(17, .semibold))
                    .foregroundStyle(Theme.peach)
                    .multilineTextAlignment(.center)
                    .frame(width: maxDigits(i) == 3 ? 36 : 25)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(focus == i ? Theme.amber.opacity(0.16) : Theme.background.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(focus == i ? Theme.amber : Theme.rule, lineWidth: 1))
                    .focused($focus, equals: i)
                    .onSubmit(commit)
                if i < 3 {
                    Text(i == 2 && usesMilliseconds ? "," : ":")
                        .font(Theme.mono(15, .semibold))
                        .foregroundStyle(Theme.textFaint)
                        .frame(width: 9)
                }
            }
        }
        .onExitCommand(perform: cancel)
        .onAppear {
            parts = split(time)
            DispatchQueue.main.async { focus = 0 }
        }
        .onChange(of: focus) { _, new in
            // Clicked somewhere else: leave without moving.
            if new == nil {
                DispatchQueue.main.async { if focus == nil { cancel() } }
            }
        }
    }

    private func binding(_ i: Int) -> Binding<String> {
        Binding(
            get: { parts[i] },
            set: { value in
                let digits = String(value.filter(\.isNumber).suffix(maxDigits(i)))
                let changed = digits != parts[i]
                parts[i] = digits
                // Full: on to the next field.
                if changed, digits.count == maxDigits(i), i < 3, focus == i { focus = i + 1 }
            }
        )
    }

    /// The shown time (with the project's start timecode) split into its four fields.
    private func split(_ t: Double) -> [String] {
        let shown = model.tc(t)
        let fields = shown.split(whereSeparator: { $0 == ":" || $0 == "," || $0 == "." || $0 == ";" }).map(String.init)
        return fields.count == 4 ? fields : ["00", "00", "00", "00"]
    }

    private func commit() {
        guard !done else { return }
        done = true
        let v = parts.map { Double($0) ?? 0 }
        let sub = usesMilliseconds ? v[3] / 1000 : v[3] * model.frameDuration
        let shown = v[0] * 3600 + v[1] * 60 + v[2] + sub
        let target = shown - (model.project?.settings.startTimecode ?? 0)
        let limit = model.engine.duration > 0 ? model.engine.duration : .greatestFiniteMagnitude
        model.editingTimecode = false
        model.placePlayhead(min(max(0, target), limit))
    }

    private func cancel() {
        guard !done else { return }
        done = true
        model.editingTimecode = false
    }
}
