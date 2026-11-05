import SwiftUI

/// Titles ▸ Settings… (⌘,). Kept deliberately short.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Jog speed") {
                    HStack(spacing: 8) {
                        Text("Slower").font(Theme.label(11)).foregroundStyle(Theme.textDim)
                        Slider(value: $model.jogSpeed, in: 0.25...3)
                            .frame(width: 180)
                        Text("Faster").font(Theme.label(11)).foregroundStyle(Theme.textDim)
                        Text(String(format: "%.2g×", model.jogSpeed))
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.peach)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Text("How far a title edge moves when you hold Control or Option and move the mouse.")
                    .font(Theme.label(11, .regular))
                    .foregroundStyle(Theme.textDim)
            }

            Section {
                Picker("Live spotting", selection: $model.spotMode) {
                    Text("Hold ↓ while a line is spoken").tag(SpotMode.hold)
                    Text("Tap ↓ to start next, ↑ to end").tag(SpotMode.tap)
                }
                LabeledContent("Start earlier by") {
                    Stepper(value: $model.spotStartOffset, in: 0...0.5, step: 0.01) {
                        Text("\(Int((model.spotStartOffset * 1000).rounded())) ms")
                            .font(Theme.mono(11))
                    }
                }
                LabeledContent("End earlier by") {
                    Stepper(value: $model.spotEndOffset, in: 0...0.6, step: 0.01) {
                        Text("\(Int((model.spotEndOffset * 1000).rounded())) ms")
                            .font(Theme.mono(11))
                    }
                }
                Text("Taken off each spotting key press and release. 0 ms puts the edge exactly where you pressed.")
                    .font(Theme.label(11, .regular))
                    .foregroundStyle(Theme.textDim)
            }

            Section {
                Picker("Timing preset", selection: presetBinding) {
                    ForEach(TimingPreset.all) { Text($0.name).tag($0.id) }
                }
                Toggle("Trackpad swipe over a title adjusts its edges", isOn: $model.swipeOverTitleAdjusts)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .tint(Theme.amber)
        .preferredColorScheme(.dark)
    }

    private var presetBinding: Binding<String> {
        Binding(
            get: { model.preset.id },
            set: { id in model.preset = TimingPreset.all.first { $0.id == id } ?? .general }
        )
    }
}
