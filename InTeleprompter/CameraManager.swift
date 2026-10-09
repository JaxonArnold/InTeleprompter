import AVFoundation
import Combine
import CoreMedia
import Photos
import UIKit

/// User-selectable recording quality. The camera falls back gracefully when
/// the device can't do a tier (and caps at 1080p30 while thermally throttled).
enum RecordingQuality: String, CaseIterable, Identifiable {
    case uhd60 = "4k60"
    case uhd30 = "4k30"
    case fhd60 = "1080p60"
    case fhd30 = "1080p30"

    static let storageKey = "recordingQuality"

    static var preferred: RecordingQuality {
        UserDefaults.standard.string(forKey: storageKey).flatMap(RecordingQuality.init) ?? .uhd60
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .uhd60: return "4K · 60 fps"
        case .uhd30: return "4K · 30 fps"
        case .fhd60: return "1080p · 60 fps"
        case .fhd30: return "1080p · 30 fps"
        }
    }

    var is4K: Bool { self == .uhd60 || self == .uhd30 }
    var fps: Int { self == .uhd60 || self == .fhd60 ? 60 : 30 }
}

/// A finished recording kept on disk for in-app review until the next take.
struct Take: Identifiable, Equatable {
    let url: URL
    let thumbnail: UIImage?
    let durationText: String

    var id: URL { url }
}

/// Manages the capture session at the user's chosen quality (up to 4K60),
/// with HEVC encoding, stabilization, and full-quality audio. Recording goes
/// through AVAssetWriter fed by video/audio data outputs (rather than
/// AVCaptureMovieFileOutput) so microphone sample buffers can also be tapped
/// live for speech recognition. Finished recordings are saved to the Photos
/// library and kept on disk for in-app review until the next take.
final class CameraManager: NSObject, ObservableObject {

    // MARK: - Published state

    @Published var isRecording = false
    @Published var recordingSeconds = 0
    @Published var isSessionRunning = false
    @Published var permissionDenied = false
    @Published var qualityLabel = ""
    @Published var saveMessage: String?
    @Published var cameraPosition: AVCaptureDevice.Position = .front
    /// The session was interrupted (phone call, camera claimed by another
    /// app, backgrounded). Any in-flight recording is finished and saved.
    @Published var isInterrupted = false
    /// Device is running hot (serious/critical); quality is capped at
    /// 1080p30 between takes until it cools down.
    @Published var thermalWarning = false
    /// The most recent finished recording, available for in-app review.
    @Published var lastTake: Take?
    /// The active camera, published so the preview can coordinate rotation.
    @Published private(set) var activeVideoDevice: AVCaptureDevice?

    /// A quality change arrived mid-recording; apply it when the take ends.
    private var needsReconfigure = false
    /// Files whose Photos hand-off is still in flight (main-thread only) —
    /// they must not be deleted until the save completes.
    private var pendingSaveURLs: Set<URL> = []
    /// Monotonic take counter (main-thread only). A late publish from an
    /// earlier take can't resurrect itself once a newer take has started.
    private var takeSequence = 0
    /// A start was requested but the first frame hasn't landed yet
    /// (main-thread only). Blocks overlapping starts — a second writer
    /// would silently no-op while startRecording() reported success — and
    /// lets interruption handlers clean up a take that never got rolling.
    private(set) var isPreparingToRecord = false

    // MARK: - Capture objects

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "teleprompter.session.queue")
    private let outputQueue = DispatchQueue(label: "teleprompter.output.queue")
    // nonisolated: the sample-buffer delegate (nonisolated, on outputQueue)
    // compares against these to route buffers.
    nonisolated let videoOutput = AVCaptureVideoDataOutput()
    nonisolated let audioOutput = AVCaptureAudioDataOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var audioDeviceInput: AVCaptureDeviceInput?
    private var durationTimer: Timer?
    /// Gravity-aware rotation for recordings; gives the correct angle per
    /// camera in any interface orientation.
    private var captureRotationCoordinator: AVCaptureDevice.RotationCoordinator?

    // MARK: - Writer state (touched only on outputQueue — nonisolated(unsafe)
    // makes the queue confinement explicit under MainActor default isolation;
    // outputQueue provides the synchronization, checked by dispatchPrecondition)

    nonisolated(unsafe) private var assetWriter: AVAssetWriter?
    nonisolated(unsafe) private var writerVideoInput: AVAssetWriterInput?
    nonisolated(unsafe) private var writerAudioInput: AVAssetWriterInput?
    nonisolated(unsafe) private var writerSessionStarted = false
    nonisolated(unsafe) private var writerTakeSequence = 0

    /// Live tap on microphone sample buffers; called on a background queue
    /// for every audio buffer, whether or not a recording is in progress.
    nonisolated(unsafe) private var audioSampleHandler: ((CMSampleBuffer) -> Void)?

    func setAudioSampleHandler(_ handler: ((CMSampleBuffer) -> Void)?) {
        outputQueue.async { [weak self] in
            self?.audioSampleHandler = handler
        }
    }

    // MARK: - Lifecycle

    private var notificationTokens: [NSObjectProtocol] = []

    override init() {
        super.init()
        addObservers()
        thermalWarning = Self.isThermallyThrottled
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    /// Request permissions, configure for maximum quality, and start the session.
    func start() {
        Task { [weak self] in
            let cameraOK = await Self.requestAccess(for: .video)
            let micOK = await Self.requestAccess(for: .audio)
            guard let self else { return }
            guard cameraOK, micOK else {
                await MainActor.run { self.permissionDenied = true }
                return
            }
            sessionQueue.async { [weak self] in
                guard let self else { return }
                self.configureSession()
                if !self.session.isRunning { self.session.startRunning() }
                let running = self.session.isRunning
                DispatchQueue.main.async { self.isSessionRunning = running }
            }
        }
    }

    func stop() {
        stopRecording()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isSessionRunning = false }
        }
    }

    // MARK: - Interruptions & thermal state

    private func addObservers() {
        let center = NotificationCenter.default
        notificationTokens = [
            // Phone call, Siri, camera claimed by another app, backgrounding:
            // never lose the take — finish the file and save it.
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                               object: session, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.isInterrupted = true
                if self.isRecording {
                    self.saveMessage = "Recording interrupted — saving your take"
                }
                // Also stop a take that was requested but never got its first
                // frame — otherwise its writer waits forever for buffers an
                // interrupted session will never deliver.
                if self.isRecording || self.isPreparingToRecord {
                    self.stopRecording()
                }
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                               object: session, queue: .main) { [weak self] _ in
                self?.isInterrupted = false
            },
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                               object: session, queue: .main) { [weak self] note in
                guard let self else { return }
                if self.isRecording {
                    self.saveMessage = "Camera error — saving your take"
                }
                if self.isRecording || self.isPreparingToRecord {
                    self.stopRecording()
                }
                // The system can reset media services (e.g. after a long
                // interruption); the session must be restarted by hand.
                if let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError,
                   error.code == AVError.mediaServicesWereReset.rawValue {
                    self.sessionQueue.async { [weak self] in
                        guard let self, !self.session.isRunning else { return }
                        self.session.startRunning()
                    }
                }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                               object: nil, queue: .main) { [weak self] _ in
                guard let self, self.isRecording || self.isPreparingToRecord else { return }
                if self.isRecording {
                    self.saveMessage = "Recording stopped in background — saving your take"
                }
                self.stopRecording()
            },
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                               object: nil, queue: .main) { [weak self] _ in
                self?.handleThermalChange()
            },
        ]
    }

    private static var isThermallyThrottled: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }

    private func handleThermalChange() {
        let throttled = Self.isThermallyThrottled
        guard throttled != thermalWarning else { return }
        thermalWarning = throttled
        // Apply the new quality cap between takes — never mid-recording
        // (that would break the file); stopRecording reapplies it instead.
        if !isRecording, isSessionRunning {
            sessionQueue.async { [weak self] in self?.configureSession() }
        }
    }

    private static func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: mediaType)
        default:
            return false
        }
    }

    // MARK: - Session configuration

    private func configureSession() {
        session.beginConfiguration()
        let configured = configureSessionContent()
        session.commitConfiguration()

        guard let (camera, resolutionLabel, quality) = configured else {
            // No camera could be attached (simulator, hardware failure) —
            // clear published state so the UI and the preview's rotation
            // coordinator don't keep pointing at a device that is no longer
            // in the session.
            DispatchQueue.main.async {
                self.activeVideoDevice = nil
                self.qualityLabel = ""
            }
            return
        }

        let fpsLabel = applyCaptureTweaks(camera: camera, quality: quality)
        DispatchQueue.main.async { self.qualityLabel = resolutionLabel + fpsLabel }

        // A different physical camera (flip, or first configure) starts from
        // automatic center-weighted focus/exposure, and any exposure bias the
        // user dialed in is re-applied against the new device's range.
        if camera !== configuredDevice {
            configuredDevice = camera
            resetFocusAndExposure(on: camera)
            let clamped = min(max(appliedExposureBias, camera.minExposureTargetBias),
                              camera.maxExposureTargetBias)
            if clamped != 0 {
                updateDevice(camera) { camera.setExposureTargetBias(clamped) }
            }
            DispatchQueue.main.async {
                self.focusState = .automatic
                self.exposureBias = clamped
                self.exposureBiasRange = camera.minExposureTargetBias...camera.maxExposureTargetBias
            }
        }
    }

    /// Removes and re-adds all inputs/outputs and picks the preset. Runs on
    /// sessionQueue between beginConfiguration() and commitConfiguration().
    /// Returns nil when no camera could be attached.
    private func configureSessionContent() -> (camera: AVCaptureDevice, resolutionLabel: String, quality: RecordingQuality)? {
        // Clean slate (also used when flipping cameras).
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        videoDeviceInput = nil
        audioDeviceInput = nil
        captureRotationCoordinator = nil

        // -- Video input: prefer the best physical camera available.
        guard let camera = bestCamera(for: cameraPosition),
              let videoInput = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(videoInput) else { return nil }
        session.addInput(videoInput)
        videoDeviceInput = videoInput
        captureRotationCoordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
        DispatchQueue.main.async { self.activeVideoDevice = camera }

        // -- Audio input.
        if let mic = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
            audioDeviceInput = audioInput
        }

        // -- The user's chosen quality, capped at 1080p30 when the device is
        // running hot so the session keeps running instead of being
        // throttled by the system.
        var quality = RecordingQuality.preferred
        if Self.isThermallyThrottled { quality = .fhd30 }

        var presets: [(AVCaptureSession.Preset, String)] = [
            (.hd1920x1080, "1080p"),
            (.high, "High"),
        ]
        if quality.is4K {
            presets.insert((.hd4K3840x2160, "4K"), at: 0)
        }
        var resolutionLabel = "High"
        for (preset, label) in presets where session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
            resolutionLabel = label
            break
        }

        // -- Data outputs feeding the asset writer and the live audio tap.
        // Late frames must be discarded: the camera has a small fixed buffer
        // pool, and if downstream (HEVC encode + writer) falls behind, holding
        // frames stalls the entire capture pipeline — frozen preview included.
        // A dropped frame in the file is the better failure.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(videoOutput) else { return nil }
        session.addOutput(videoOutput)

        audioOutput.setSampleBufferDelegate(self, queue: outputQueue)
        if let connection = videoOutput.connection(with: .video),
           connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .auto
        }
        // Note: no rotation on this connection. On a data output that would
        // physically rotate every 4K frame; portrait orientation is applied
        // as free transform metadata on the writer input instead.
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }

        return (camera, resolutionLabel, quality)
    }

    /// Frame-rate lock and smooth AF / low-light tweaks. Runs after commit,
    /// so activeFormat reflects the newly committed preset — checking before
    /// commit tests the previous preset's format, which can silently miss a
    /// 60 fps lock on capable hardware (or apply one the new format clamps).
    private func applyCaptureTweaks(camera: AVCaptureDevice, quality: RecordingQuality) -> String {
        guard (try? camera.lockForConfiguration()) != nil else { return "" }
        defer { camera.unlockForConfiguration() }

        var fpsLabel = ""
        if camera.activeFormat.videoSupportedFrameRateRanges
            .contains(where: { $0.maxFrameRate >= Double(quality.fps) }) {
            let duration = CMTime(value: 1, timescale: CMTimeScale(quality.fps))
            camera.activeVideoMinFrameDuration = duration
            camera.activeVideoMaxFrameDuration = duration
            fpsLabel = " · \(quality.fps)fps"
        }

        // Smooth exposure/focus changes look better on video.
        if camera.isSmoothAutoFocusSupported { camera.isSmoothAutoFocusEnabled = true }
        if camera.isLowLightBoostSupported { camera.automaticallyEnablesLowLightBoostWhenAvailable = true }

        return fpsLabel
    }

    /// Picks the most capable camera at the given position.
    private func bestCamera(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let preferredTypes: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: preferredTypes,
            mediaType: .video,
            position: position
        )
        return discovery.devices.first
    }

    // MARK: - Focus & exposure control

    /// Metering/focusing mode, published for the focus indicator and the
    /// exposure slider's enabled state.
    enum FocusState: Equatable {
        case automatic         // continuous, center-weighted (default)
        case pointOfInterest   // continuous AF/AE at the held point
        case locked            // hard AE/AF lock (extended hold)
    }
    @Published private(set) var focusState: FocusState = .automatic
    /// Exposure compensation in EV, clamped to the active device's range.
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var exposureBiasRange: ClosedRange<Float> = -3...3

    // MARK: Focus/exposure state (touched only on sessionQueue)

    /// The device the session is currently configured with.
    nonisolated(unsafe) private var configuredDevice: AVCaptureDevice?
    /// Bias as applied to the hardware (mirrored to exposureBias for the UI).
    nonisolated(unsafe) private var appliedExposureBias: Float = 0

    /// Hold-to-focus: focus and meter at a point (device coordinates, 0–1),
    /// continuously — the chosen subject stays metered as the shot changes.
    func setPointOfInterest(_ point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            self.updateDevice(device) {
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .continuousAutoExposure
                }
            }
            DispatchQueue.main.async { self.focusState = .pointOfInterest }
        }
    }

    /// Extended hold: hard-lock focus and exposure at a point — nothing hunts,
    /// no matter what moves through the frame.
    func lockFocusAndExposure(at point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            self.updateDevice(device) {
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                }
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            }
            DispatchQueue.main.async { self.focusState = .locked }
        }
    }

    /// Back to center-weighted continuous everything (lock-badge tap,
    /// camera flip).
    func resetFocusAndExposure() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            self.resetFocusAndExposure(on: device)
            DispatchQueue.main.async { self.focusState = .automatic }
        }
    }

    /// Exposure compensation in EV. Values outside the active device's
    /// range are clamped, and the clamped value is published back.
    func setExposureBias(_ bias: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDeviceInput?.device else { return }
            let clamped = min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias)
            self.appliedExposureBias = clamped
            self.updateDevice(device) { device.setExposureTargetBias(clamped) }
            DispatchQueue.main.async {
                self.exposureBias = clamped
                self.exposureBiasRange = device.minExposureTargetBias...device.maxExposureTargetBias
            }
        }
    }

    /// Runs on sessionQueue.
    private func resetFocusAndExposure(on device: AVCaptureDevice) {
        updateDevice(device) {
            let center = CGPoint(x: 0.5, y: 0.5)
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = center }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = center }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        }
    }

    /// Locks the device for a configuration change; no-ops when unavailable.
    /// Runs on sessionQueue.
    private func updateDevice(_ device: AVCaptureDevice, _ changes: () -> Void) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        changes()
        device.unlockForConfiguration()
    }

    // MARK: - Controls

    func flipCamera() {
        cameraPosition = (cameraPosition == .front) ? .back : .front
        sessionQueue.async { [weak self] in
            self?.configureSession()
        }
    }

    /// The quality preference changed; apply it now, or at the end of the
    /// current take if one is in progress.
    func applyQualityChange() {
        if isRecording {
            needsReconfigure = true
        } else if isSessionRunning {
            sessionQueue.async { [weak self] in self?.configureSession() }
        }
    }

    /// Returns false when recording can't start (e.g. storage is full).
    @discardableResult
    func startRecording() -> Bool {
        // A start is already in flight; a second writer would silently
        // no-op on outputQueue while this method reported success.
        guard !isPreparingToRecord else { return false }
        // The session is interrupted (call, camera claimed elsewhere): the
        // writer would sit forever waiting for a first frame that never comes.
        guard !isInterrupted else {
            saveMessage = "Camera is interrupted — try again in a moment."
            return false
        }
        let free = Self.freeDiskSpace()
        if free < Self.minimumSpaceToRecord {
            saveMessage = "Not enough free storage to record — free up space and try again."
            return false
        }
        if free < Self.lowSpaceWarningThreshold {
            let minutes = max(1, free / estimatedBytesPerMinute)
            saveMessage = "Storage is low — roughly \(minutes) min of recording left."
        }
        takeSequence += 1
        let sequence = takeSequence
        // The previous take's review copy is superseded by the new one. If
        // its Photos save is still in flight, the save's completion deletes
        // the file instead — removing it now would lose the take.
        if let previous = lastTake {
            lastTake = nil
            if !pendingSaveURLs.contains(previous.url) {
                Task.detached(priority: .utility) {
                    try? FileManager.default.removeItem(at: previous.url)
                }
            }
        }
        // Lock this take's orientation to how the phone is held right now;
        // rotating mid-take keeps the file at its starting orientation.
        let captureAngle = captureRotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        isPreparingToRecord = true
        outputQueue.async { [weak self] in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(self.outputQueue))
            guard self.assetWriter == nil else {
                DispatchQueue.main.async { self.isPreparingToRecord = false }
                return
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("take-" + UUID().uuidString)
                .appendingPathExtension("mov")
            do {
                let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

                var videoSettings = self.videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mov)
                if self.videoOutput.availableVideoCodecTypesForAssetWriter(writingTo: .mov).contains(.hevc),
                   let hevcSettings = self.videoOutput.recommendedVideoSettings(
                       forVideoCodecType: .hevc, assetWriterOutputFileType: .mov) {
                    videoSettings = hevcSettings
                }
                let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                videoInput.expectsMediaDataInRealTime = true
                // Buffers arrive in sensor-native orientation; rotate to the
                // take's orientation via metadata (free, unlike rotating pixels).
                videoInput.transform = CGAffineTransform(rotationAngle: captureAngle * .pi / 180)
                guard writer.canAdd(videoInput) else { throw RecordingError.cannotConfigureWriter }
                writer.add(videoInput)

                let audioSettings = self.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioInput.expectsMediaDataInRealTime = true
                if writer.canAdd(audioInput) { writer.add(audioInput) }

                guard writer.startWriting() else { throw writer.error ?? RecordingError.cannotConfigureWriter }

                self.assetWriter = writer
                self.writerVideoInput = videoInput
                self.writerAudioInput = audioInput
                self.writerSessionStarted = false
                self.writerTakeSequence = sequence
                // isPreparingToRecord clears when the first frame starts the
                // writer session (see captureOutput), or in stopRecording().
            } catch {
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async {
                    self.isPreparingToRecord = false
                    self.saveMessage = "Recording failed: \(error.localizedDescription)"
                }
            }
        }
        return true
    }

    func stopRecording() {
        // Keep the process alive until the file is finished and handed to
        // Photos — interruption-triggered stops (calls, backgrounding) land
        // exactly when the app is about to be suspended.
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FinishRecording") {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        let finish = {
            DispatchQueue.main.async {
                guard backgroundTask != .invalid else { return }
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }

        outputQueue.async { [weak self] in
            guard let self, let writer = self.assetWriter else {
                finish()
                return
            }
            dispatchPrecondition(condition: .onQueue(self.outputQueue))
            let videoInput = self.writerVideoInput
            let audioInput = self.writerAudioInput
            let sessionStarted = self.writerSessionStarted
            let sequence = self.writerTakeSequence
            self.assetWriter = nil
            self.writerVideoInput = nil
            self.writerAudioInput = nil
            self.writerSessionStarted = false

            DispatchQueue.main.async {
                self.isRecording = false
                self.isPreparingToRecord = false
                self.stopDurationTimer()
                // Apply any deferred quality change (settings picker or a
                // mid-take thermal cap) now that the take is finished.
                if self.thermalWarning || self.needsReconfigure {
                    self.needsReconfigure = false
                    self.sessionQueue.async { self.configureSession() }
                }
            }

            guard sessionStarted else {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: writer.outputURL)
                finish()
                return
            }
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            let outputURL = writer.outputURL
            DispatchQueue.main.async { self.pendingSaveURLs.insert(outputURL) }
            // Strong self, deliberately: these one-shot completions always
            // run, and the save pipeline must outlive the CameraManager —
            // the prompter (its owner) can be dismissed while the writer
            // finalizes, and a weak reference here would silently drop
            // the take.
            writer.finishWriting {
                if writer.status == .completed {
                    self.publishTake(for: writer.outputURL, sequence: sequence) {
                        self.saveToPhotos(url: writer.outputURL, completion: finish)
                    }
                } else {
                    let reason = writer.error?.localizedDescription ?? "unknown error"
                    try? FileManager.default.removeItem(at: writer.outputURL)
                    DispatchQueue.main.async {
                        self.pendingSaveURLs.remove(writer.outputURL)
                        self.saveMessage = "Recording failed: \(reason)"
                    }
                    finish()
                }
            }
        }
    }

    private enum RecordingError: LocalizedError {
        case cannotConfigureWriter
        var errorDescription: String? { "couldn't configure the video writer" }
    }

    // MARK: - Storage

    /// Removes review copies left behind by earlier sessions (the prompter
    /// closing keeps the last take's file on disk). Call at app launch,
    /// when no recording can be in progress.
    static func purgeStaleTakes() {
        Task.detached(priority: .utility) {
            let manager = FileManager.default
            guard let files = try? manager.contentsOfDirectory(
                at: manager.temporaryDirectory, includingPropertiesForKeys: nil) else { return }
            for file in files where file.lastPathComponent.hasPrefix("take-") {
                try? manager.removeItem(at: file)
            }
        }
    }

    /// Below this, recording is refused outright.
    private static let minimumSpaceToRecord: Int64 = 300_000_000
    /// Below this, recording proceeds with a warning.
    private static let lowSpaceWarningThreshold: Int64 = 2_000_000_000

    /// Rough write rate at the current quality, for the low-space estimate.
    private var estimatedBytesPerMinute: Int64 {
        if Self.isThermallyThrottled { return 80_000_000 }  // capped at 1080p30
        switch RecordingQuality.preferred {
        case .uhd60: return 450_000_000
        case .uhd30: return 250_000_000
        case .fhd60: return 130_000_000
        case .fhd30: return 80_000_000
        }
    }

    private static func freeDiskSpace() -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    // MARK: - Duration timer

    private func startDurationTimer() {
        recordingSeconds = 0
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.recordingSeconds += 1
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    var recordingTimeText: String {
        String(format: "%02d:%02d", recordingSeconds / 60, recordingSeconds % 60)
    }

    // MARK: - Saving

    /// Builds the review thumbnail/duration off the main thread, publishes
    /// the finished take, then runs `completion` on the main thread. Strong
    /// self so the publish survives the prompter being dismissed. The
    /// sequence check keeps a slow publish from resurrecting an old take
    /// after a newer recording has already started — and publishing strictly
    /// before the Photos hand-off finishes keeps `finishPendingSave` from
    /// deleting the file out from under the review.
    private func publishTake(for url: URL, sequence: Int, completion: @escaping () -> Void) {
        Task.detached(priority: .utility) { [self] in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 400)
            let cgImage = try? await generator.image(at: .zero).image
            let seconds = Int(((try? await asset.load(.duration).seconds) ?? 0).rounded())
            let take = Take(
                url: url,
                thumbnail: cgImage.map(UIImage.init(cgImage:)),
                durationText: String(format: "%d:%02d", seconds / 60, seconds % 60)
            )
            await MainActor.run {
                if sequence == self.takeSequence {
                    self.lastTake = take
                }
                completion()
            }
        }
    }

    private func saveToPhotos(url: URL, completion: @escaping () -> Void = {}) {
        // Strong self: the Photos hand-off must complete — and the review
        // copy must be reconciled — even if the prompter was dismissed.
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [self] status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self.saveMessage = "Couldn't save: allow Photos access in Settings."
                    self.protectReviewCopy(at: url)
                    self.finishPendingSave(of: url)
                }
                completion()
                return
            }
            // The file stays on disk for in-app review until the next take.
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    self.saveMessage = success
                        ? "Saved to Photos"
                        : "Couldn't save: \(error?.localizedDescription ?? "unknown error")"
                    self.protectReviewCopy(at: url)
                    self.finishPendingSave(of: url)
                }
                completion()
            }
        }
    }

    /// Upgrades the review copy to complete file protection, matching
    /// scripts.json. Can't happen before the Photos hand-off — a locked
    /// device would make the file unreadable mid-save — but afterwards the
    /// copy is only read while the device is unlocked (in-app review).
    private func protectReviewCopy(at url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    /// The Photos hand-off for this file is done; if a newer take superseded
    /// it while the save was in flight, its review copy can now be removed.
    private func finishPendingSave(of url: URL) {
        pendingSaveURLs.remove(url)
        if lastTake?.url != url {
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

// MARK: - Sample buffer delegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate,
                         AVCaptureAudioDataOutputSampleBufferDelegate {

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        dispatchPrecondition(condition: .onQueue(outputQueue))
        if output === audioOutput {
            audioSampleHandler?(sampleBuffer)
        }
        guard let writer = assetWriter else { return }

        if output === videoOutput {
            // Anchor the writer timeline to the first video frame so the
            // recording never opens with audio-only (black) content.
            if !writerSessionStarted {
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                writerSessionStarted = true
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.isPreparingToRecord = false
                    self.startDurationTimer()
                }
            }
            if let input = writerVideoInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        } else if writerSessionStarted,
                  let input = writerAudioInput, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }
}
