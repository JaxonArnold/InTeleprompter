import SwiftUI
import AVFoundation
import Combine

/// Scroll position and word layout for the script panel, isolated from the
/// rest of the prompter: the 60 fps scroll tick mutates `offset` every frame
/// and the voice tracker advances through words several times a second, so
/// whatever observes this object re-renders at that rate. Keeping it out of
/// PrompterView's own @State confines that churn to the panel below.
final class PrompterScrollState: ObservableObject {
    @Published var offset: CGFloat = 0
    @Published var textHeight: CGFloat = 0
    @Published var wordYPositions: [CGFloat] = []
    /// One remote-scrub step, in points (~two text lines; the panel keeps
    /// it in step with the current font size and line spacing).
    var scrubStep: CGFloat = 56

    func nearestWordIndex(toTextY targetY: CGFloat) -> Int? {
        guard !wordYPositions.isEmpty else { return nil }
        var nearest = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, y) in wordYPositions.enumerated() where abs(y - targetY) < bestDistance {
            bestDistance = abs(y - targetY)
            nearest = index
        }
        return nearest
    }

    /// Point the tracker at the word currently sitting on the reading guide.
    func alignTracker(to tracker: SpeechScriptTracker) {
        guard let nearest = nearestWordIndex(toTextY: -offset) else { return }
        tracker.seek(to: nearest)
    }

    func reset() {
        withAnimation(.easeOut(duration: 0.25)) { offset = 0 }
    }
}

struct PrompterView: View {
    let script: Script
    /// Markup parsed once: display text for rendering/tracking, styles for
    /// the text view, cue ranges the tracker skips.
    private let formattedScript: FormattedScript

    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraManager()
    @StateObject private var remotes = RemoteControlService()
    // Held in plain @State (not @StateObject/@ObservedObject): any @Published
    // change on an observed object invalidates the holding view, and these
    // two change at frame/word rate. Only the subviews that need the updates
    // observe them.
    @State private var tracker: SpeechScriptTracker
    @State private var scroll = PrompterScrollState()

    init(script: Script) {
        self.script = script
        let formatted = ScriptFormatter.parse(script.body)
        formattedScript = formatted
        _tracker = State(wrappedValue: SpeechScriptTracker(
            scriptText: formatted.text,
            excludingRanges: formatted.speakerCueRanges
        ))
    }

    // Persisted prompter settings
    @AppStorage("scrollSpeed") private var scrollSpeed = 60.0        // points per second
    @AppStorage("mirrored") private var mirrored = false
    @AppStorage("framingAids") private var framingAids = false
    @AppStorage("countdownEnabled") private var countdownEnabled = true
    @AppStorage("autoScrollOnRecord") private var autoScrollOnRecord = true
    @AppStorage("voiceFollowEnabled") private var voiceFollowEnabled = false
    @AppStorage(RecordingQuality.storageKey) private var recordingQuality = RecordingQuality.uhd60.rawValue
    @AppStorage("hasSeenPrompterHints") private var hasSeenPrompterHints = false

    // UI state
    @State private var isScrolling = false
    @State private var controlsVisible = true
    @State private var showSettings = false
    @State private var reviewTake: Take?
    @State private var showHints = false
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    /// Bumped to hand key focus back to the remote-keys view after a sheet
    /// or cover (settings, take review) dismisses.
    @State private var remoteReclaim = 0

    // Focus & exposure control
    @State private var previewLayerBox = CameraPreviewLayerBox()
    @State private var focusIndicator: FocusIndicator?
    @State private var focusFadeTask: Task<Void, Never>?
    /// Holding the preview focuses; holding longer escalates to a lock.
    @GestureState private var isHoldingFocus = false
    @State private var holdFocusFired = false
    @State private var focusLockTask: Task<Void, Never>?
    /// SwiftUI taps fire even after long holds, so a hold that focused
    /// suppresses the controls toggle its touch-up would otherwise trigger.
    @State private var tapSuppressedUntil = Date.distantPast
    /// When the current take started, for remotes to count up from locally.
    @State private var recordingStartedAt: Date?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Mirror mode is for beam-splitter rigs: the device is a
                // display under the glass, so the preview is replaced with
                // plain black and the script takes the whole screen.
                if !mirrored {
                    CameraPreviewView(session: camera.session,
                                      device: camera.activeVideoDevice,
                                      layerBox: previewLayerBox)
                        .ignoresSafeArea()
                        .overlay {
                            if let focusIndicator {
                                focusIndicatorView(focusIndicator)
                            }
                        }
                        // Focus is press-and-hold only, so a quick tap falls
                        // through to the controls toggle — the tap people use
                        // to find the stop button mid-take. Attached here (not
                        // the ZStack) so coordinates match the preview layer.
                        .gesture(holdFocusGesture)
                }

                PrompterScriptPanel(
                    bodyText: formattedScript.text,
                    styles: formattedScript.styles,
                    tracker: tracker,
                    scroll: scroll,
                    size: geo.size,
                    isScrolling: $isScrolling
                )

                // Bluetooth page-turner pedals, scrolling rings, and iPad
                // keyboards — all plain HID keyboards as far as iOS knows.
                RemoteKeysView(reclaimToken: remoteReclaim, onKey: handleRemoteKey)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)

                if framingAids, !mirrored {
                    RuleOfThirdsGrid()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                if let countdown {
                    countdownOverlay(countdown)
                }

                VStack {
                    if controlsVisible { topBar }
                    Spacer()
                    if let message = camera.saveMessage {
                        toast(message)
                    } else if camera.isInterrupted {
                        toast("Camera paused — in use by another app or a call")
                    } else if voiceFollowEnabled, tracker.status == .denied {
                        toast("Allow speech recognition in Settings to use voice tracking")
                    }
                    if controlsVisible, !camera.isRecording, let take = camera.lastTake {
                        HStack {
                            TakeThumbnailButton(take: take) {
                                isScrolling = false
                                reviewTake = take
                            }
                            Spacer()
                        }
                        .padding(.bottom, 4)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    if controlsVisible { bottomBar }
                }
                .padding(.horizontal, 16)
                .animation(.easeInOut(duration: 0.2), value: controlsVisible)

                if camera.permissionDenied {
                    permissionDeniedOverlay
                }

                if showHints {
                    hintsOverlay
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !holdFocusFired, Date() >= tapSuppressedUntil else { return }
                if showHints {
                    dismissHints()
                } else {
                    withAnimation { controlsVisible.toggle() }
                }
            }
            .onChange(of: geo.size) { _, _ in
                // The indicator's position is meaningless after relayout.
                focusIndicator = nil
            }
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(true)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            camera.start()
            remotes.onCommand = handleRemoteCommand
            remotes.start()
            publishRemoteState()
            if voiceFollowEnabled { tracker.requestAuthorization() }
            if !hasSeenPrompterHints {
                Task {
                    try? await Task.sleep(for: .seconds(0.7))
                    withAnimation { showHints = true }
                }
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            countdownTask?.cancel()
            focusFadeTask?.cancel()
            focusLockTask?.cancel()
            remotes.stop()
            tracker.pause()
            camera.setAudioSampleHandler(nil)
            camera.stop()
        }
        .onChange(of: isScrolling) { _, scrolling in
            guard voiceFollowEnabled else {
                publishRemoteState()
                return
            }
            if scrolling { startVoiceFollow() } else { tracker.pause() }
            publishRemoteState()
        }
        .onChange(of: camera.isRecording) { wasRecording, recording in
            // Recording can end without the stop button — interruption,
            // backgrounding, runtime error. Don't keep scrolling into a
            // take that no longer exists.
            if wasRecording && !recording {
                isScrolling = false
                withAnimation { controlsVisible = true }
            }
            if recording && !wasRecording {
                recordingStartedAt = Date()
            } else if !recording {
                recordingStartedAt = nil
            }
            publishRemoteState()
        }
        .onChange(of: camera.isInterrupted) { _, interrupted in
            if interrupted {
                // An interruption mid-countdown must not start a recording
                // into a session that delivers no frames.
                countdownTask?.cancel()
                countdown = nil
                Haptics.warning()
            }
        }
        .onChange(of: voiceFollowEnabled) { _, enabled in
            if enabled {
                tracker.requestAuthorization()
                if isScrolling { startVoiceFollow() }
            } else {
                tracker.pause()
                camera.setAudioSampleHandler(nil)
            }
        }
        .onChange(of: camera.saveMessage) { _, message in
            guard let message else { return }
            Task {
                try? await Task.sleep(for: .seconds(3))
                // Only clear if a newer message hasn't replaced this one.
                if camera.saveMessage == message { camera.saveMessage = nil }
            }
        }
        .onChange(of: recordingQuality) { _, _ in
            camera.applyQualityChange()
        }
        .onChange(of: reviewTake) { _, take in
            if take == nil { remoteReclaim += 1 }
        }
        .onChange(of: showSettings) { _, show in
            if !show { remoteReclaim += 1 }
        }
        .onChange(of: isHoldingFocus) { _, holding in
            // Gesture state also resets when the system cancels the gesture,
            // so cleanup lives here rather than in onEnded.
            if !holding { endHoldFocus() }
        }
        .onChange(of: camera.focusState) { _, state in
            // Camera flipped or focus reset: the indicator no longer applies.
            if state == .automatic {
                focusFadeTask?.cancel()
                if focusIndicator != nil {
                    withAnimation { focusIndicator = nil }
                }
            }
        }
        .onChange(of: scrollSpeed) { _, _ in
            publishRemoteState()
        }
        .sheet(isPresented: $showSettings) {
            PrompterSettingsView(camera: camera)
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $reviewTake) { take in
            TakeReviewView(take: take)
        }
        .alert("Allow Remote Control?",
               isPresented: Binding(
                   get: { remotes.pendingPeerName != nil },
                   set: { if !$0 { remotes.declinePendingPeer() } }
               )) {
            Button("Allow") { remotes.acceptPendingPeer() }
            Button("Decline", role: .cancel) { remotes.declinePendingPeer() }
        } message: {
            if let name = remotes.pendingPeerName {
                Text("“\(name)” wants to control this prompter.")
            }
        }
    }

    private func startVoiceFollow() {
        scroll.alignTracker(to: tracker)
        camera.setAudioSampleHandler { [weak tracker] buffer in
            tracker?.append(buffer)
        }
        tracker.start()
    }

    // MARK: - Remote keys (pedals, rings, iPad keyboard)

    private func handleRemoteKey(_ key: RemoteKey) {
        switch key {
        case .playPause:
            Haptics.tap()
            isScrolling.toggle()
        case .recordToggle:
            toggleRecording()
        case .scrubBack:
            // Scrubbing keeps the scroll running (or paused) as it was;
            // while voice-following, re-anchor the tracker at the new spot.
            scroll.offset += scroll.scrubStep
            if voiceFollowEnabled { scroll.alignTracker(to: tracker) }
        case .scrubForward:
            scroll.offset -= scroll.scrubStep
            if voiceFollowEnabled { scroll.alignTracker(to: tracker) }
        case .speedDown:
            scrollSpeed = max(10, scrollSpeed - 10)
        case .speedUp:
            scrollSpeed = min(240, scrollSpeed + 10)
        case .reset:
            resetScroll()
        }
    }

    // MARK: - Remote control (second device)

    private func handleRemoteCommand(_ command: RemoteCommand) {
        switch command {
        case .toggleRecord:
            toggleRecording()
        case .toggleScroll:
            Haptics.tap()
            isScrolling.toggle()
        case .speedUp:
            scrollSpeed = min(240, scrollSpeed + 10)
        case .speedDown:
            scrollSpeed = max(10, scrollSpeed - 10)
        case .resetScroll:
            resetScroll()
        }
    }

    /// Latest-wins state snapshot for any connected peer.
    /// Recording time travels as a start date — remotes count up locally,
    /// so this never needs to fire more than once per actual change.
    private func publishRemoteState() {
        remotes.publish(RemoteState(
            isPrompterActive: true,
            isRecording: camera.isRecording,
            recordingStartedAt: recordingStartedAt,
            isScrolling: isScrolling,
            scrollSpeed: scrollSpeed
        ))
    }

    private func resetScroll() {
        scroll.reset()
        isScrolling = false
        tracker.seek(to: 0)
        Haptics.tap()
    }

    // MARK: - Focus & exposure control

    /// How long to hold the preview before focus/metering moves there.
    private static let holdToFocusDuration = 0.35
    /// Further hold, after focusing, that escalates to a hard AE/AF lock.
    private static let holdToLockDelay = 0.8

    /// Press-and-hold with location: sequence a zero-distance drag after the
    /// press completes and read the finger position from it.
    private var holdFocusGesture: some Gesture {
        LongPressGesture(minimumDuration: Self.holdToFocusDuration)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($isHoldingFocus) { value, holding, _ in
                if case .second(true, _) = value { holding = true }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value, let drag,
                      !holdFocusFired else { return }
                holdFocusFired = true
                beginHoldFocus(at: drag.location)
            }
    }

    /// Hold reached: focus and meter at that point, continuously, and arm the
    /// lock in case the finger stays down.
    private func beginHoldFocus(at location: CGPoint) {
        guard let layer = previewLayerBox.layer else { return }
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: location)
        Haptics.tap()
        camera.setPointOfInterest(devicePoint)
        focusFadeTask?.cancel()
        withAnimation(.spring(duration: 0.25)) {
            focusIndicator = FocusIndicator(point: location, locked: false)
        }
        focusLockTask?.cancel()
        focusLockTask = Task {
            try? await Task.sleep(for: .seconds(Self.holdToLockDelay))
            guard !Task.isCancelled else { return }
            lockFocus(at: location, devicePoint: devicePoint)
        }
    }

    /// Still holding: hard-lock focus and exposure at that point.
    private func lockFocus(at location: CGPoint, devicePoint: CGPoint) {
        Haptics.action()
        camera.lockFocusAndExposure(at: devicePoint)
        focusFadeTask?.cancel()
        withAnimation(.spring(duration: 0.25)) {
            focusIndicator = FocusIndicator(point: location, locked: true)
        }
    }

    /// Finger lifted (or the gesture was cancelled).
    private func endHoldFocus() {
        focusLockTask?.cancel()
        focusLockTask = nil
        guard holdFocusFired else { return }
        holdFocusFired = false
        // See tapSuppressedUntil: the touch-up must not also toggle controls.
        tapSuppressedUntil = Date().addingTimeInterval(0.35)
        // An unlocked indicator fades once focus has settled; a locked one
        // stays until released.
        guard focusIndicator?.locked == false else { return }
        focusFadeTask?.cancel()
        focusFadeTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, focusIndicator?.locked == false else { return }
            withAnimation { focusIndicator = nil }
        }
    }

    private func focusIndicatorView(_ indicator: FocusIndicator) -> some View {
        // When locked the badge is a button: tapping it releases the lock.
        // Unlocked it's display-only, so taps fall through to the preview.
        Button {
            guard indicator.locked else { return }
            focusIndicator = nil
            camera.resetFocusAndExposure()
        } label: {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(indicator.locked ? Color.orange : Color.yellow,
                                  lineWidth: 2)
                    .frame(width: 76, height: 76)
                if indicator.locked {
                    Label("AE/AF", systemImage: "lock.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                }
            }
        }
        .buttonStyle(.plain)
        .allowsHitTesting(indicator.locked)
        .position(indicator.point)
        .transition(.scale(scale: 1.4).combined(with: .opacity))
        .accessibilityLabel(indicator.locked
                            ? "Focus and exposure locked — tap to unlock"
                            : "Focus point")
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            CircleIconButton(systemName: "xmark") {
                if camera.isRecording { camera.stopRecording() }
                dismiss()
            }

            Spacer(minLength: 8)

            if camera.isRecording {
                HStack(spacing: 7) {
                    Circle()
                        .fill(.red)
                        .frame(width: 9, height: 9)
                    Text(camera.recordingTimeText)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.black.opacity(0.55), in: Capsule())
            } else if !camera.qualityLabel.isEmpty {
                Text(camera.qualityLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if camera.thermalWarning {
                Image(systemName: "thermometer.high")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 32, height: 32)
                    .background(.black.opacity(0.55), in: Circle())
                    .accessibilityLabel("Device is hot — quality reduced")
            }

            if remotes.hasRemote {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .frame(width: 32, height: 32)
                    .background(.black.opacity(0.55), in: Circle())
                    .accessibilityLabel("A remote is connected")
            }

            CircleIconButton(systemName: "arrow.triangle.2.circlepath.camera") {
                Haptics.tap()
                camera.flipCamera()
            }
            .disabled(camera.isRecording)
            .opacity(camera.isRecording ? 0.4 : 1)

            CircleIconButton(systemName: "slider.horizontal.3") {
                showSettings = true
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 0) {
            CircleIconButton(systemName: "backward.end.fill", action: resetScroll)

            Spacer(minLength: 8)

            if voiceFollowEnabled {
                VoiceStatusPill(tracker: tracker, isScrolling: isScrolling)
            } else {
                speedStepper
            }

            Spacer(minLength: 8)

            recordButton

            Spacer(minLength: 8)

            CircleIconButton(systemName: isScrolling ? "pause.fill" : "play.fill") {
                Haptics.tap()
                isScrolling.toggle()
            }

            Spacer(minLength: 8)

            voiceToggleButton
        }
        .padding(.bottom, 18)
    }

    /// Mirror moved to Settings to make room; this toggles voice-following.
    private var voiceToggleButton: some View {
        Button {
            Haptics.tap()
            voiceFollowEnabled.toggle()
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(voiceFollowEnabled ? .black : .white)
                .frame(width: 44, height: 44)
                .background(
                    voiceFollowEnabled ? AnyShapeStyle(.yellow) : AnyShapeStyle(.black.opacity(0.55)),
                    in: Circle()
                )
        }
        .accessibilityLabel(voiceFollowEnabled ? "Turn off voice tracking" : "Turn on voice tracking")
    }

    private var speedStepper: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                Button {
                    scrollSpeed = max(10, scrollSpeed - 10)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 30, height: 30)
                }
                Text("\(Int(scrollSpeed))")
                    .font(.system(.callout, design: .monospaced).weight(.bold))
                    .frame(width: 36)
                Button {
                    scrollSpeed = min(240, scrollSpeed + 10)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 30, height: 30)
                }
            }
            .background(.black.opacity(0.55), in: Capsule())
            Text("speed")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
    }

    private var recordButton: some View {
        Button(action: toggleRecording) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 72, height: 72)
                RoundedRectangle(cornerRadius: camera.isRecording ? 7 : 29)
                    .fill(.red)
                    .frame(
                        width: camera.isRecording ? 30 : 58,
                        height: camera.isRecording ? 30 : 58
                    )
                    .animation(.easeInOut(duration: 0.2), value: camera.isRecording)
            }
        }
        .disabled(camera.isInterrupted)
        .opacity(camera.isInterrupted ? 0.4 : 1)
        .accessibilityLabel(camera.isRecording ? "Stop recording" : "Start recording")
    }

    // MARK: - Recording flow

    private func toggleRecording() {
        if camera.isRecording {
            Haptics.action()
            camera.stopRecording()
            isScrolling = false
            return
        }
        if countdown != nil {
            countdownTask?.cancel()
            countdown = nil
            return
        }
        if countdownEnabled {
            countdownTask = Task {
                for value in stride(from: 3, through: 1, by: -1) {
                    await MainActor.run {
                        countdown = value
                        Haptics.tap()
                    }
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                }
                await MainActor.run {
                    countdown = nil
                    beginRecording()
                }
            }
        } else {
            beginRecording()
        }
    }

    private func beginRecording() {
        // A countdown can outlive an interruption that began mid-count —
        // starting into an interrupted session would create a writer that
        // waits forever for its first frame.
        guard !camera.isInterrupted, camera.startRecording() else { return }
        Haptics.action()
        if autoScrollOnRecord { isScrolling = true }
        // Clean framing while rolling — tap anywhere to bring controls back.
        withAnimation { controlsVisible = false }
    }

    // MARK: - First-run hints

    private var hintsOverlay: some View {
        VStack(alignment: .leading, spacing: 18) {
            hintRow(icon: "hand.tap", text: "Tap anywhere to show or hide the controls")
            hintRow(icon: "viewfinder", text: "Press and hold the preview to focus there — keep holding to lock focus and exposure")
            hintRow(icon: "arrow.up.and.down", text: "Drag the script to move through it")
            hintRow(icon: "arrow.up.left.and.arrow.down.right", text: "Pinch to resize the text")

            Button {
                dismissHints()
            } label: {
                Text("Got it")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
        }
        .padding(26)
        .frame(maxWidth: 340)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .padding(32)
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    private func hintRow(icon: String, text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .frame(width: 32)
                .foregroundStyle(.yellow)
            Text(text)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func dismissHints() {
        hasSeenPrompterHints = true
        withAnimation { showHints = false }
    }

    // MARK: - Overlays

    private func countdownOverlay(_ value: Int) -> some View {
        Text("\(value)")
            .font(.system(size: 130, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 12)
            .transition(.scale.combined(with: .opacity))
            .id(value)
            .animation(.spring(duration: 0.3), value: value)
    }

    private func toast(_ message: String) -> some View {
        Text(message)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.7), in: Capsule())
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var permissionDeniedOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Camera & microphone access needed")
                .font(.headline)
            Text("Enable both in Settings to record with the teleprompter.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            Button("Close") { dismiss() }
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(36)
    }
}

// MARK: - Scrolling script panel

/// The scrolling script panel. Owns the per-frame scroll machinery (tick,
/// gestures, word layout) and observes the scroll state and the tracker, so
/// the 60 fps tick and per-word voice updates re-render only this view —
/// not the record button, bars, or camera preview around it.
private struct PrompterScriptPanel: View {
    let bodyText: String
    let styles: [StyleSpan]
    @ObservedObject var tracker: SpeechScriptTracker
    @ObservedObject var scroll: PrompterScrollState
    let size: CGSize
    @Binding var isScrolling: Bool

    @AppStorage("scrollSpeed") private var scrollSpeed = 60.0
    @AppStorage("fontSize") private var fontSize = 34.0
    @AppStorage("lineSpacing") private var lineSpacing = 10.0
    @AppStorage("sideMargin") private var sideMargin = 24.0
    @AppStorage("overlayOpacity") private var overlayOpacity = 0.55
    @AppStorage("panelHeightFraction") private var panelHeightFraction = 0.55
    @AppStorage("mirrored") private var mirrored = false
    @AppStorage("voiceFollowEnabled") private var voiceFollowEnabled = false

    @State private var dragStartOffset: CGFloat?
    @State private var lastTick: Date?
    @State private var pinchBaseFontSize: Double?
    @State private var pinchAnchorIndex: Int?

    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        // Mirror mode (beam-splitter rigs): the script fills the screen.
        let panelHeight = mirrored ? size.height : size.height * panelHeightFraction
        let guideY = panelHeight * 0.32

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // The script is an overlay so its (very tall) natural height
                // can't inflate the panel — otherwise the fixed-height frame
                // below centers the oversized stack and the prompter opens
                // mid-script.
                Color.black.opacity(overlayOpacity)
                    .overlay(alignment: .top) {
                        scriptText(width: size.width)
                            .offset(y: guideY + scroll.offset)
                    }

                // Fade the text out at the panel edges.
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.9), location: 0),
                        .init(color: .clear, location: 0.12),
                        .init(color: .clear, location: 0.85),
                        .init(color: .black.opacity(0.9), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .allowsHitTesting(false)

                // Reading guide line.
                Rectangle()
                    .fill(guideColor)
                    .animation(.easeInOut(duration: 0.25), value: guideColor)
                    .frame(width: 34, height: 3)
                    .clipShape(Capsule())
                    .offset(x: 10, y: guideY + 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
            }
            .frame(height: panelHeight)
            .clipped()
            .scaleEffect(x: mirrored ? -1 : 1, y: 1)
            .gesture(scrubGesture)
            .simultaneousGesture(pinchGesture)

            Spacer(minLength: 0)
        }
        .ignoresSafeArea(edges: .top)
        .overlay {
            if pinchBaseFontSize != nil {
                fontSizeHUD
            }
        }
        .onReceive(tick) { now in advanceScroll(at: now) }
        .onChange(of: size.width) { oldWidth, newWidth in
            // Rotation reflows the script; keep the same word at the
            // guide line through the relayout.
            guard oldWidth > 0, oldWidth != newWidth else { return }
            pinchAnchorIndex = scroll.nearestWordIndex(toTextY: -scroll.offset)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                pinchAnchorIndex = nil
            }
        }
        .onChange(of: tracker.status) { old, new in
            if new == .tracking, old != .tracking { Haptics.lock() }
        }
    }

    private func scriptText(width: CGFloat) -> some View {
        let textWidth = max(width - sideMargin * 2, 100)
        return PrompterTextView(
            text: bodyText,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            width: textWidth,
            styles: styles,
            wordRanges: tracker.wordRanges,
            readWordCount: voiceFollowEnabled ? tracker.currentWordIndex : 0
        ) { height, positions in
            scroll.textHeight = height
            scroll.wordYPositions = positions
            // Remote scrubbing steps ~two lines at the current text size.
            scroll.scrubStep = (fontSize + lineSpacing) * 2
            // Keep the same word under the guide while pinch-resizing.
            if let anchor = pinchAnchorIndex, positions.indices.contains(anchor) {
                scroll.offset = -positions[anchor]
            }
        }
        .frame(width: textWidth, alignment: .leading)
        .padding(.horizontal, sideMargin)
    }

    private var scrubGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                // A two-finger pinch also registers as a drag; don't let the
                // two fight over the scroll position.
                guard pinchBaseFontSize == nil else {
                    dragStartOffset = nil
                    return
                }
                if dragStartOffset == nil { dragStartOffset = scroll.offset }
                scroll.offset = (dragStartOffset ?? 0) + value.translation.height
            }
            .onEnded { _ in
                dragStartOffset = nil
                // Dragging while voice-following repositions the tracker too,
                // so you can skip ahead (or back) and keep reading from there.
                if voiceFollowEnabled { scroll.alignTracker(to: tracker) }
            }
    }

    /// When voice-following has lost the speaker, the guide line turns orange.
    private var guideColor: Color {
        guard voiceFollowEnabled, isScrolling else { return .yellow.opacity(0.85) }
        return tracker.status == .tracking ? .green.opacity(0.85) : .orange.opacity(0.85)
    }

    private func advanceScroll(at now: Date) {
        guard isScrolling, dragStartOffset == nil else {
            // Idle: write nothing, so the 60 fps tick costs no re-render.
            // (Only write on the transition — @State invalidates per write.)
            if lastTick != nil { lastTick = nil }
            return
        }
        // Use real elapsed time, not an assumed 1/60 s: main-thread timers
        // jitter under load and ProMotion displays don't tick at 60 Hz.
        // Capped so a stall (e.g. returning from a sheet) can't cause a leap.
        let dt = min(lastTick.map { now.timeIntervalSince($0) } ?? 1.0 / 60.0, 0.1)
        lastTick = now
        if voiceFollowEnabled {
            guard let target = voiceTargetOffset() else { return }
            // Ease toward the word being spoken, capped at a comfortable pace.
            let maxStep: CGFloat = 500.0 * dt
            let step = (target - scroll.offset) * min(3.6 * dt, 1)
            scroll.offset += min(max(step, -maxStep), maxStep)
        } else {
            scroll.offset -= scrollSpeed * dt
            if scroll.offset < -(scroll.textHeight + 40) {
                isScrolling = false   // reached the end
                Haptics.tap()
            }
        }
    }

    /// Offset that puts the next expected word on the reading guide.
    private func voiceTargetOffset() -> CGFloat? {
        guard !scroll.wordYPositions.isEmpty else { return nil }
        let index = min(tracker.currentWordIndex, scroll.wordYPositions.count - 1)
        return -scroll.wordYPositions[index]
    }

    // MARK: Pinch to resize

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if pinchBaseFontSize == nil {
                    pinchBaseFontSize = fontSize
                    pinchAnchorIndex = scroll.nearestWordIndex(toTextY: -scroll.offset)
                }
                let target = (pinchBaseFontSize ?? fontSize) * value
                // Whole-point steps so the text isn't re-laid-out every frame.
                fontSize = min(max(target.rounded(), 20), 64)
            }
            .onEnded { _ in
                pinchBaseFontSize = nil
                // Hold the anchor through the final relayout, then let go.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    pinchAnchorIndex = nil
                }
            }
    }

    private var fontSizeHUD: some View {
        Text("\(Int(fontSize)) pt")
            .font(.title3.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.black.opacity(0.7), in: Capsule())
    }
}

// MARK: - Voice status pill

/// Observes the tracker so per-word `currentWordIndex` updates invalidate
/// only this pill, not the bars around it.
private struct VoiceStatusPill: View {
    @ObservedObject var tracker: SpeechScriptTracker
    let isScrolling: Bool

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                Text(statusText)
            }
            .font(.system(.callout).weight(.semibold))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(.black.opacity(0.55), in: Capsule())

            Text("voice")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
    }

    private var statusText: String {
        guard isScrolling else { return "ready" }
        switch tracker.status {
        case .idle: return "ready"
        case .listening: return "listening…"
        case .tracking: return "following"
        case .denied: return "no mic access"
        case .unavailable: return "unavailable"
        }
    }
}

// MARK: - Framing aids

/// Rule-of-thirds grid over the preview, for lining up your eyeline with
/// the lens. Drawn once per layout via Canvas — cheap even while scrolling.
private struct RuleOfThirdsGrid: View {
    var body: some View {
        Canvas { context, size in
            let color = Color.white.opacity(0.28)
            for x in [size.width / 3, size.width * 2 / 3] {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(color), lineWidth: 0.5)
            }
            for y in [size.height / 3, size.height * 2 / 3] {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(color), lineWidth: 0.5)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Focus indicator model

/// A focus point in preview coordinates. `locked` turns it into the
/// tappable AE/AF lock badge.
private struct FocusIndicator: Equatable {
    var point: CGPoint
    var locked: Bool
}

// MARK: - Reusable circular icon button

private struct CircleIconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.55), in: Circle())
        }
    }
}
