import SwiftUI

struct PrompterSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("scrollSpeed") private var scrollSpeed = 60.0
    @AppStorage("fontSize") private var fontSize = 34.0
    @AppStorage("lineSpacing") private var lineSpacing = 10.0
    @AppStorage("sideMargin") private var sideMargin = 24.0
    @AppStorage("overlayOpacity") private var overlayOpacity = 0.55
    @AppStorage("panelHeightFraction") private var panelHeightFraction = 0.55
    @AppStorage("mirrored") private var mirrored = false
    @AppStorage("countdownEnabled") private var countdownEnabled = true
    @AppStorage("autoScrollOnRecord") private var autoScrollOnRecord = true
    @AppStorage("voiceFollowEnabled") private var voiceFollowEnabled = false
    @AppStorage(RecordingQuality.storageKey) private var recordingQuality = RecordingQuality.uhd60.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    LabeledSlider(title: "Font size", value: $fontSize,
                                  range: 20...64, format: "%.0f pt")
                    LabeledSlider(title: "Line spacing", value: $lineSpacing,
                                  range: 0...28, format: "%.0f pt")
                    LabeledSlider(title: "Side margins", value: $sideMargin,
                                  range: 8...80, format: "%.0f pt")
                }

                Section {
                    LabeledSlider(title: "Speed", value: $scrollSpeed,
                                  range: 10...240, format: "%.0f pt/s")
                    Toggle("Start scrolling when recording starts", isOn: $autoScrollOnRecord)
                    Toggle("Follow my voice", isOn: $voiceFollowEnabled)
                } header: {
                    Text("Scrolling")
                } footer: {
                    Text("With voice tracking on, the script follows your reading and pauses when you stop or go off script. Speech is processed on-device whenever your language supports it.")
                }

                Section("Display") {
                    LabeledSlider(title: "Background dim", value: $overlayOpacity,
                                  range: 0...0.95, format: "%.0f%%", scale: 100)
                    LabeledSlider(title: "Panel height", value: $panelHeightFraction,
                                  range: 0.3...0.85, format: "%.0f%%", scale: 100)
                    Toggle("Mirror text (beam-splitter rigs)", isOn: $mirrored)
                }

                Section {
                    Picker("Quality", selection: $recordingQuality) {
                        ForEach(RecordingQuality.allCases) { quality in
                            Text(quality.label).tag(quality.rawValue)
                        }
                    }
                    Toggle("3-second countdown", isOn: $countdownEnabled)
                } header: {
                    Text("Recording")
                } footer: {
                    Text("Lower quality saves storage and battery on long sessions. Quality changes apply to the next take.")
                }

                Section {
                    Button("Reset to defaults", role: .destructive) {
                        scrollSpeed = 60
                        fontSize = 34
                        lineSpacing = 10
                        sideMargin = 24
                        overlayOpacity = 0.55
                        panelHeightFraction = 0.55
                        mirrored = false
                        countdownEnabled = true
                        autoScrollOnRecord = true
                        voiceFollowEnabled = false
                        recordingQuality = RecordingQuality.uhd60.rawValue
                    }
                }
            }
            .navigationTitle("Prompter Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var scale: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value * scale))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
        .padding(.vertical, 2)
    }
}
