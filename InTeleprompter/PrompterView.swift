import SwiftUI
import AVFoundation
import Combine

struct PrompterView: View {
    let script: Script

    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraManager()
    @StateObject private var tracker: SpeechScriptTracker

    init(script: Script) {
        self.script = script
        _tracker = StateObject(wrappedValue: SpeechScriptTracker(scriptText: script.body))
    }

    // Persisted prompter settings
    @AppStorage("scrollSpeed") private var scrollSpeed = 60.0        // points per second
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
    @AppStorage("hasSeenPrompterHints") private var hasSeenPrompterHints = false

    // Scroll engine
    @State private var offset: CGFloat = 0
    @State private var dragStartOffset: CGFloat?
    @State private var isScrolling = false
    @State private var lastTick: Date?
    @State private var textHeight: CGFloat = 0
    @State private var wordYPositions: [CGFloat] = []

    // UI state
    @State private var controlsVisible = true
    @State private var showSettings = false
    @State private var reviewTake: Take?
    @State private var showHints = false

    // Pinch-to-resize
    @State private var pinchBaseFontSize: Double?
    @State private var pinchAnchorIndex: Int?
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?

    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                CameraPreviewView(session: camera.session, device: camera.activeVideoDevice)
                    .ignoresSafeArea()

                prompterPanel(in: geo)

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

                if pinchBaseFontSize != nil {
                    fontSizeHUD
                }

                if camera.permissionDenied {
                    permissionDeniedOverlay
                }

                if showHints {
                    hintsOverlay
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if showHints {
                    dismissHints()
                } else {
                    withAnimation { controlsVisible.toggle() }
                }
            }
            .onChange(of: geo.size.width) { oldWidth, newWidth in
                // Rotation reflows the script; keep the same word at the
                // guide line through the relayout.
                guard oldWidth > 0, oldWidth != newWidth else { return }
                pinchAnchorIndex = nearestWordIndex(toTextY: -offset)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    pinchAnchorIndex = nil
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(true)
        .onReceive(tick) { now in advanceScroll(at: now) }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            camera.start()
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
            tracker.pause()
            camera.setAudioSampleHandler(nil)
            camera.stop()
        }
        .onChange(of: isScrolling) { _, scrolling in
            guard voiceFollowEnabled else { return }
            if scrolling { startVoiceFollow() } else { tracker.pause() }
        }
        .onChange(of: camera.isRecording) { wasRecording, recording in
            // Recording can end without the stop button — interruption,
            // backgrounding, runtime error. Don't keep scrolling into a
            // take that no longer exists.
            if wasRecording && !recording {
                isScrolling = false
                withAnimation { controlsVisible = true }
            }
        }
        .onChange(of: tracker.status) { old, new in
            if new == .tracking, old != .tracking { Haptics.lock() }
        }
        .onChange(of: camera.isInterrupted) { _, interrupted in
            if interrupted { Haptics.warning() }
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
        .sheet(isPresented: $showSettings) {
            PrompterSettingsView()
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $reviewTake) { take in
            TakeReviewView(take: take)
        }
    }

    // MARK: - Scrolling text panel

    private func prompterPanel(in geo: GeometryProxy) -> some View {
        let panelHeight = geo.size.height * panelHeightFraction
        let guideY = panelHeight * 0.32

        return VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // The script is an overlay so its (very tall) natural height
                // can't inflate the panel — otherwise the fixed-height frame
                // below centers the oversized stack and the prompter opens
                // mid-script.
                Color.black.opacity(overlayOpacity)
                    .overlay(alignment: .top) {
                        scriptText(width: geo.size.width)
                            .offset(y: guideY + offset)
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
    }

    private func scriptText(width: CGFloat) -> some View {
        let textWidth = max(width - sideMargin * 2, 100)
        return PrompterTextView(
            text: script.body,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            width: textWidth,
            wordRanges: tracker.wordRanges,
            readWordCount: voiceFollowEnabled ? tracker.currentWordIndex : 0
        ) { height, positions in
            textHeight = height
            wordYPositions = positions
            // Keep the same word under the guide while pinch-resizing.
            if let anchor = pinchAnchorIndex, positions.indices.contains(anchor) {
                offset = -positions[anchor]
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
                if dragStartOffset == nil { dragStartOffset = offset }
                offset = (dragStartOffset ?? 0) + value.translation.height
            }
            .onEnded { _ in
                dragStartOffset = nil
                // Dragging while voice-following repositions the tracker too,
                // so you can skip ahead (or back) and keep reading from there.
                if voiceFollowEnabled { alignTrackerToScroll() }
            }
    }

    /// When voice-following has lost the speaker, the guide line turns orange.
    private var guideColor: Color {
        guard voiceFollowEnabled, isScrolling else { return .yellow.opacity(0.85) }
        return tracker.status == .tracking ? .green.opacity(0.85) : .orange.opacity(0.85)
    }

    private func advanceScroll(at now: Date) {
        // Use real elapsed time, not an assumed 1/60 s: main-thread timers
        // jitter under load and ProMotion displays don't tick at 60 Hz.
        // Capped so a stall (e.g. returning from a sheet) can't cause a leap.
        let dt = min(lastTick.map { now.timeIntervalSince($0) } ?? 1.0 / 60.0, 0.1)
        lastTick = now
        guard isScrolling, dragStartOffset == nil else { return }
        if voiceFollowEnabled {
            guard let target = voiceTargetOffset() else { return }
            // Ease toward the word being spoken, capped at a comfortable pace.
            let maxStep: CGFloat = 500.0 * dt
            let step = (target - offset) * min(3.6 * dt, 1)
            offset += min(max(step, -maxStep), maxStep)
        } else {
            offset -= scrollSpeed * dt
            if offset < -(textHeight + 40) {
                isScrolling = false   // reached the end
                Haptics.tap()
            }
        }
    }

    /// Offset that puts the next expected word on the reading guide.
    private func voiceTargetOffset() -> CGFloat? {
        guard !wordYPositions.isEmpty else { return nil }
        let index = min(tracker.currentWordIndex, wordYPositions.count - 1)
        return -wordYPositions[index]
    }

    private func nearestWordIndex(toTextY targetY: CGFloat) -> Int? {
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
    private func alignTrackerToScroll() {
        guard let nearest = nearestWordIndex(toTextY: -offset) else { return }
        tracker.seek(to: nearest)
    }

    // MARK: - Pinch to resize

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if pinchBaseFontSize == nil {
                    pinchBaseFontSize = fontSize
                    pinchAnchorIndex = nearestWordIndex(toTextY: -offset)
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

    private func startVoiceFollow() {
        alignTrackerToScroll()
        camera.setAudioSampleHandler { [weak tracker] buffer in
            tracker?.append(buffer)
        }
        tracker.start()
    }

    private func resetScroll() {
        withAnimation(.easeOut(duration: 0.25)) { offset = 0 }
        isScrolling = false
        tracker.seek(to: 0)
        Haptics.tap()
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
                voiceStatusPill
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

    private var voiceStatusPill: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                Text(voiceStatusText)
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

    private var voiceStatusText: String {
        guard isScrolling else { return "ready" }
        switch tracker.status {
        case .idle: return "ready"
        case .listening: return "listening…"
        case .tracking: return "following"
        case .denied: return "no mic access"
        case .unavailable: return "unavailable"
        }
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
        guard camera.startRecording() else { return }
        Haptics.action()
        if autoScrollOnRecord { isScrolling = true }
        // Clean framing while rolling — tap anywhere to bring controls back.
        withAnimation { controlsVisible = false }
    }

    // MARK: - First-run hints

    private var hintsOverlay: some View {
        VStack(alignment: .leading, spacing: 18) {
            hintRow(icon: "hand.tap", text: "Tap anywhere to show or hide the controls")
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
