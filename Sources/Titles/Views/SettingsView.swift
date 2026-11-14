import SwiftUI

/// KPTN.SUB ▸ Settings… (⌘,). Kept deliberately short. Reading speed and line rules
/// live per project (File ▸ Project Settings…).
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Jog with the mouse (hold Control for the start, Option for the end)") {
                Toggle("Moving the mouse moves the edge", isOn: $model.mouseJogOn)
                Picker("Each step moves", selection: $model.mouseJogStep) {
                    ForEach(JogStep.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!model.mouseJogOn)
                SensitivitySlider(value: $model.mouseJogSensitivity, low: "Finer", high: "Faster",
                                  readout: String(format: "%.0f pt per step", 40 * pow(2.0 / 40, model.mouseJogSensitivity)))
                    .disabled(!model.mouseJogOn)
                Text("Every step needs the same mouse travel, however fast you move, and a sudden jerk can't throw an edge far. Hold Shift for steps ten times bigger.")
                    .font(Theme.label(11, .regular))
                    .foregroundStyle(Theme.textDim)
            }

            Section("Jog with the scroll wheel or a two-finger swipe") {
                Toggle("The wheel moves the edge", isOn: $model.wheelJogOn)
                Picker("Each step moves", selection: $model.wheelJogStep) {
                    ForEach(JogStep.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!model.wheelJogOn)
                SensitivitySlider(value: $model.wheelJogSensitivity, low: "Finer", high: "Faster",
                                  readout: Self.wheelReadout(model.wheelJogSensitivity))
                    .disabled(!model.wheelJogOn)
                Text("One wheel click back always undoes one click forward. If your mouse's own software smooths scrolling (Logi Options+, for example), turn that off for KPTN.SUB for exactly one step per click.")
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
                Toggle("Enable overlapping titles", isOn: $model.allowOverlaps)
                Text(model.allowOverlaps
                     ? "A dragged title stops at the minimum gap from the next one; pull a little further and it goes over it. Once they're apart again, it stops again."
                     : "A dragged title stops at the minimum gap from the next one and never goes over it. Titles that already overlap (in an imported file) stay as they are.")
                    .font(Theme.label(11, .regular))
                    .foregroundStyle(Theme.textDim)
            }

            Section {
                Toggle("Trackpad swipe over the selected title adjusts its edges", isOn: $model.swipeOverTitleAdjusts)
                Toggle("Replay title after jog or nudge", isOn: $model.replayAfterJog)
                Toggle("Replay title after drag-resize", isOn: $model.replayAfterResize)
                Toggle("Replay title after dragging it to a new time", isOn: $model.replayAfterMove)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .tint(Theme.amber)
        .preferredColorScheme(.dark)
    }

    static func wheelReadout(_ v: Double) -> String {
        let perClick = pow(16, v) / 4
        if perClick >= 1 { return String(format: "%.1f steps per click", perClick) }
        return String(format: "1 step per %.1f clicks", 1 / perClick)
    }
}

/// A 0…1 slider with words at each end and the value it means.
private struct SensitivitySlider: View {
    @Binding var value: Double
    let low: String
    let high: String
    let readout: String

    var body: some View {
        LabeledContent("Sensitivity") {
            HStack(spacing: 8) {
                Text(low).font(Theme.label(11)).foregroundStyle(Theme.textDim)
                Slider(value: $value, in: 0...1).frame(width: 160)
                Text(high).font(Theme.label(11)).foregroundStyle(Theme.textDim)
                Text(readout)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.peach)
                    .frame(width: 130, alignment: .trailing)
            }
        }
    }
}
