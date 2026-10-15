import AVFoundation
import Combine
import SwiftUI

/// Live microphone level from the capture session, polled 15 times a
/// second. Kept apart from CameraManager so only the meter redraws, not the
/// whole prompter.
@MainActor
final class AudioLevelMeter: ObservableObject {
    /// 0 (silence) … 1 (full scale): rises instantly, falls gently.
    @Published private(set) var level: Float = 0
    /// Peaks reached full scale within the last second.
    @Published private(set) var isClipping = false

    private var timer: Timer?
    private var clippingUntil = Date.distantPast

    func start(channels: @escaping @MainActor () -> [AVCaptureAudioChannel]) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(channels()) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        level = 0
        isClipping = false
    }

    private func update(_ channels: [AVCaptureAudioChannel]) {
        let average = channels.map(\.averagePowerLevel).max() ?? -160
        let peak = channels.map(\.peakHoldLevel).max() ?? -160
        let target = Self.normalized(average)
        level = target > level ? target : max(target, level - 0.04)
        if peak > -1 { clippingUntil = Date().addingTimeInterval(1) }
        let clipping = Date() < clippingUntil
        if clipping != isClipping { isClipping = clipping }
    }

    /// -50 dB … 0 dB onto 0 … 1.
    nonisolated static func normalized(_ decibels: Float) -> Float {
        min(1, max(0, (decibels + 50) / 50))
    }
}

/// A small mic level bar: green while talking normally, yellow when loud,
/// red when the signal clips.
struct AudioLevelMeterView: View {
    @ObservedObject var meter: AudioLevelMeter

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(meter.isClipping ? .red : .white)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.25))
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(meter.level))
                }
            }
            .frame(width: 44, height: 5)
            .animation(.linear(duration: 1.0 / 15), value: meter.level)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue(meter.isClipping ? "Too loud" : meter.level < 0.2 ? "Quiet" : "Good")
    }

    private var color: Color {
        if meter.isClipping || meter.level > 0.94 { return .red }   // above about -3 dB
        if meter.level > 0.76 { return .yellow }                   // above about -12 dB
        return .green
    }
}

/// The microphones iOS offers right now (built-in, wired, USB-C, and AirPods
/// where supported), and which one records. The choice is remembered and
/// re-applied whenever the prompter opens; if that mic isn't connected, iOS
/// uses its default.
@MainActor
final class MicrophoneManager: ObservableObject {
    struct Microphone: Identifiable, Hashable {
        let id: String
        let name: String
        let symbol: String
    }

    @Published private(set) var microphones: [Microphone] = []
    @Published private(set) var currentID: String?

    static let storageKey = "preferredMicrophone"
    private var routeObserver: NSObjectProtocol?

    init() {
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    /// Re-applies the saved choice. Call once the capture session is running:
    /// it sets up the audio session, and inputs only appear after that.
    func applySavedChoice() {
        let session = AVAudioSession.sharedInstance()
        if let saved = UserDefaults.standard.string(forKey: Self.storageKey),
           let port = session.availableInputs?.first(where: { $0.uid == saved }) {
            try? session.setPreferredInput(port)
        }
        refresh()
    }

    func select(_ id: String) {
        UserDefaults.standard.set(id, forKey: Self.storageKey)
        applySavedChoice()
    }

    func refresh() {
        let session = AVAudioSession.sharedInstance()
        microphones = (session.availableInputs ?? []).map {
            Microphone(id: $0.uid, name: $0.portName, symbol: Self.symbol(for: $0.portType))
        }
        // Until the capture session starts there's no active input; show the
        // mic it will use: the saved choice if it's connected, else the first.
        let saved = UserDefaults.standard.string(forKey: Self.storageKey)
        currentID = session.currentRoute.inputs.first?.uid
            ?? microphones.first { $0.id == saved }?.id
            ?? microphones.first?.id
    }

    private static func symbol(for port: AVAudioSession.Port) -> String {
        switch port {
        case .builtInMic: return "iphone"
        case .headsetMic: return "headphones"
        case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP: return "airpods"
        case .usbAudio: return "cable.connector"
        case .carAudio: return "car"
        default: return "mic"
        }
    }
}
