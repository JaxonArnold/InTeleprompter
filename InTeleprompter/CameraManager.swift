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

    // MARK: - Capture objects

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "teleprompter.session.queue")
    private let outputQueue = DispatchQueue(label: "teleprompter.output.queue")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var audioDeviceInput: AVCaptureDeviceInput?
    private var durationTimer: Timer?
    /// Gravity-aware rotation for recordings; gives the correct angle per
    /// camera in any interface orientation.
    private var captureRotationCoordinator: AVCaptureDevice.RotationCoordinator?

    // MARK: - Writer state (touched only on outputQueue)

    private var assetWriter: AVAssetWriter?
    private var writerVideoInput: AVAssetWriterInput?
    private var writerAudioInput: AVAssetWriterInput?
    private var writerSessionStarted = false

    /// Live tap on microphone sample buffers; called on a background queue
    /// for every audio buffer, whether or not a recording is in progress.
    private var audioSampleHandler: ((CMSampleBuffer) -> Void)?

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
        Task {
            let cameraOK = await Self.requestAccess(for: .video)
            let micOK = await Self.requestAccess(for: .audio)
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
                guard let self, self.isRecording else { return }
                self.saveMessage = "Recording stopped in background — saving your take"
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
        defer { session.commitConfiguration() }

        // Clean slate (also used when flipping cameras).
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)

        // -- Video input: prefer the best physical camera available.
        guard let camera = bestCamera(for: cameraPosition),
              let videoInput = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(videoInput) else { return }
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

        // -- Apply the requested frame rate if the active format allows it.
        var fpsLabel = ""
        if camera.activeFormat.videoSupportedFrameRateRanges
            .contains(where: { $0.maxFrameRate >= Double(quality.fps) }) {
            do {
                try camera.lockForConfiguration()
                let duration = CMTime(value: 1, timescale: CMTimeScale(quality.fps))
                camera.activeVideoMinFrameDuration = duration
                camera.activeVideoMaxFrameDuration = duration
                camera.unlockForConfiguration()
                fpsLabel = " · \(quality.fps)fps"
            } catch {
                // Keep the format's default frame rate.
            }
        }

        // Smooth exposure/focus changes look better on video.
        if (try? camera.lockForConfiguration()) != nil {
            if camera.isSmoothAutoFocusSupported { camera.isSmoothAutoFocusEnabled = true }
            if camera.isLowLightBoostSupported { camera.automaticallyEnablesLowLightBoostWhenAvailable = true }
            camera.unlockForConfiguration()
        }

        // -- Data outputs feeding the asset writer and the live audio tap.
        // Late frames must be discarded: the camera has a small fixed buffer
        // pool, and if downstream (HEVC encode + writer) falls behind, holding
        // frames stalls the entire capture pipeline — frozen preview included.
        // A dropped frame in the file is the better failure.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(videoOutput) else { return }
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

        DispatchQueue.main.async { self.qualityLabel = resolutionLabel + fpsLabel }
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
        let free = Self.freeDiskSpace()
        if free < Self.minimumSpaceToRecord {
            saveMessage = "Not enough free storage to record — free up space and try again."
            return false
        }
        if free < Self.lowSpaceWarningThreshold {
            let minutes = max(1, free / estimatedBytesPerMinute)
            saveMessage = "Storage is low — roughly \(minutes) min of recording left."
        }
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
        outputQueue.async { [weak self] in
            guard let self, self.assetWriter == nil else { return }
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
            } catch {
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async {
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
            let videoInput = self.writerVideoInput
            let audioInput = self.writerAudioInput
            let sessionStarted = self.writerSessionStarted
            self.assetWriter = nil
            self.writerVideoInput = nil
            self.writerAudioInput = nil
            self.writerSessionStarted = false

            DispatchQueue.main.async {
                self.isRecording = false
                self.stopDurationTimer()
                // Apply any deferred quality change (settings picker or a
                // mid-take thermal cap) now that the take is finished.
                if self.thermalWarning || self.needsReconfigure {
                    self.needsReconfigure = false
                    self.sessionQueue.async { [weak self] in self?.configureSession() }
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
            writer.finishWriting { [weak self] in
                guard let self else {
                    finish()
                    return
                }
                if writer.status == .completed {
                    self.publishTake(for: writer.outputURL)
                    self.saveToPhotos(url: writer.outputURL, completion: finish)
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
        if qualityLabel.hasPrefix("4K") {
            return qualityLabel.contains("60") ? 450_000_000 : 250_000_000
        }
        return qualityLabel.contains("60") ? 130_000_000 : 80_000_000
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

    /// Builds the review thumbnail/duration off the main thread, then
    /// publishes the finished take.
    private func publishTake(for url: URL) {
        Task.detached(priority: .utility) { [weak self] in
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
            await MainActor.run { [weak self] in
                self?.lastTake = take
            }
        }
    }

    private func saveToPhotos(url: URL, completion: @escaping () -> Void = {}) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self?.saveMessage = "Couldn't save: allow Photos access in Settings."
                    self?.finishPendingSave(of: url)
                }
                completion()
                return
            }
            // The file stays on disk for in-app review until the next take.
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    self?.saveMessage = success
                        ? "Saved to Photos"
                        : "Couldn't save: \(error?.localizedDescription ?? "unknown error")"
                    self?.finishPendingSave(of: url)
                }
                completion()
            }
        }
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

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
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
