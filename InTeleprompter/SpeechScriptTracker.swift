import AVFoundation
import Combine
import Foundation
import Speech

// MARK: - Script tokenization

struct ScriptWord {
    /// The word as written in the script.
    let text: String
    /// Lowercased, letters and digits only — the form used for matching.
    let normalized: String
    /// UTF-16 range of the word in the original script text.
    let range: NSRange
}

enum ScriptTokenizer {
    static func words(in text: String) -> [ScriptWord] {
        var words: [ScriptWord] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .localized]) { substring, range, _, _ in
            guard let substring else { return }
            let normalized = normalize(substring)
            guard !normalized.isEmpty else { return }
            words.append(ScriptWord(text: substring, normalized: normalized, range: NSRange(range, in: text)))
        }
        return words
    }

    static func normalize(_ word: String) -> String {
        String(String.UnicodeScalarView(word.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }))
    }
}

// MARK: - Voice tracker

/// Follows the speaker through the script. Microphone audio is fed in as
/// sample buffers (from the capture session's audio tap); live transcription
/// results are fuzzy-matched against the script so `currentWordIndex` always
/// points at the next word expected at the reading guide. Matching only
/// searches a small window ahead of the current position, so it is cheap and
/// tolerant of misrecognized words — and when the speaker stops or goes off
/// script, the index simply stops advancing.
///
/// Recognition runs on-device when the current locale supports it, so no
/// audio leaves the phone.
final class SpeechScriptTracker: NSObject, ObservableObject {

    enum Status: Equatable {
        case idle          // not listening
        case denied        // speech recognition permission refused
        case unavailable   // no recognizer for the current locale
        case listening     // running, but not currently hearing script words
        case tracking      // locked onto the script
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var currentWordIndex = 0

    let words: [ScriptWord]
    /// Cached for the prompter's per-frame view updates.
    let wordRanges: [NSRange]

    private let recognizer: SFSpeechRecognizer?
    /// Distinctive script words used to bias the recognizer's vocabulary.
    private let contextualStrings: [String]
    /// True between start() and pause(); authorization can resolve after a
    /// quick toggle-off, in which case the task must not begin.
    private var shouldBeRunning = false
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private let requestLock = NSLock()
    private var task: SFSpeechRecognitionTask?
    /// Bumped whenever the active task changes so stale callbacks are ignored.
    private var generation = 0
    /// Number of transcription segments already matched in the current task.
    private var consumedSegments = 0
    /// The two most recent spoken tokens, for two-word re-acquisition.
    private var recentSpoken: [String] = []
    /// Internal so tests can simulate the "lost" (long-silence) state.
    var lastMatch: Date?
    private var lastResultDate: Date?
    private var decayTimer: Timer?
    private var watchdogTimer: Timer?

    init(scriptText: String) {
        let words = ScriptTokenizer.words(in: scriptText)
        self.words = words
        wordRanges = words.map(\.range)
        contextualStrings = Self.distinctiveWords(in: words)
        recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer()
        super.init()
    }

    deinit {
        decayTimer?.invalidate()
        watchdogTimer?.invalidate()
        task?.cancel()
    }

    // MARK: - Control (call on the main thread)

    /// Prompt for speech permission ahead of time (e.g. when voice mode is
    /// toggled on) so the system alert doesn't land at record start.
    func requestAuthorization() {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    func start() {
        guard status == .idle || status == .denied else { return }
        guard recognizer != nil else {
            status = .unavailable
            return
        }
        shouldBeRunning = true
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            startWatchdog()
            beginTask()
        case .notDetermined:
            startWatchdog()
            SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
                DispatchQueue.main.async {
                    guard let self, self.shouldBeRunning else { return }
                    if authorization == .authorized {
                        self.beginTask()
                    } else {
                        self.shouldBeRunning = false
                        self.status = .denied
                    }
                }
            }
        default:
            shouldBeRunning = false
            status = .denied
        }
    }

    func pause() {
        shouldBeRunning = false
        generation += 1
        endTask()
        decayTimer?.invalidate()
        decayTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if status == .listening || status == .tracking {
            status = .idle
        }
    }

    /// Jump the expected position, e.g. after the user drags the script.
    func seek(to index: Int) {
        currentWordIndex = min(max(index, 0), max(words.count - 1, 0))
        lastMatch = nil
        recentSpoken = []
    }

    /// Feed microphone audio. Safe to call from any queue.
    func append(_ sampleBuffer: CMSampleBuffer) {
        requestLock.lock()
        let request = request
        requestLock.unlock()
        request?.appendAudioSampleBuffer(sampleBuffer)
    }

    // MARK: - Recognition task

    private func beginTask() {
        guard shouldBeRunning, SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
        guard let recognizer, recognizer.isAvailable else {
            // The watchdog keeps retrying while we're supposed to be running.
            status = .unavailable
            return
        }
        generation += 1
        let gen = generation
        endTask()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.contextualStrings = contextualStrings
        requestLock.lock()
        self.request = request
        requestLock.unlock()

        consumedSegments = 0
        lastResultDate = Date()
        if status != .tracking { status = .listening }
        startDecayTimer()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                if let result {
                    self.lastResultDate = Date()
                    // Re-chunked hypotheses can merge words into one segment;
                    // split back into word tokens before matching.
                    let tokens = result.bestTranscription.segments.flatMap {
                        $0.substring.split(whereSeparator: \.isWhitespace).map(String.init)
                    }
                    self.handleTranscriptionUpdate(tokens)
                    // Restart on final results, and periodically on very long
                    // takes, so the transcription never grows unbounded.
                    if result.isFinal || tokens.count > 200 {
                        self.beginTask()
                        return
                    }
                }
                if error != nil {
                    // Tasks occasionally fail (timeouts, service restarts).
                    // Restart after a beat, keeping our script position.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        guard let self, gen == self.generation else { return }
                        self.beginTask()
                    }
                }
            }
        }
    }

    private func endTask() {
        requestLock.lock()
        request?.endAudio()
        request = nil
        requestLock.unlock()
        task?.cancel()
        task = nil
    }

    private static func distinctiveWords(in words: [ScriptWord]) -> [String] {
        var seen = Set<String>()
        var distinctive: [String] = []
        for word in words where word.text.count >= 5 && seen.insert(word.normalized).inserted {
            distinctive.append(word.text)
            if distinctive.count == 100 { break }
        }
        return distinctive
    }

    // MARK: - Matching

    /// Apply a transcription update. Partial hypotheses both grow and get
    /// re-chunked: when the recognizer rewrites its tail, the token count
    /// shrinks — and anchoring to a high-water mark would silently skip the
    /// words spoken next (readers hit this at paragraph pauses, where the
    /// recognizer loves to re-chunk). Internal so tests can drive the
    /// matching pipeline directly.
    func handleTranscriptionUpdate(_ tokens: [String]) {
        if tokens.count < consumedSegments {
            consumedSegments = tokens.count
        }
        guard tokens.count > consumedSegments else { return }
        for token in tokens[consumedSegments...] {
            match(ScriptTokenizer.normalize(token))
        }
        consumedSegments = tokens.count
    }

    /// Internal so tests can drive the matcher one token at a time.
    func match(_ spoken: String) {
        guard !spoken.isEmpty, !words.isEmpty else { return }
        let previous = recentSpoken.last
        recentSpoken.append(spoken)
        if recentSpoken.count > 2 { recentSpoken.removeFirst() }

        let lost = lastMatch.map { Date().timeIntervalSince($0) > 4 } ?? true

        // Forward: search a window ahead of the expected position; widen it
        // when we haven't matched in a while (the speaker may have skipped).
        let window = lost ? 30 : 12
        // Single-word matches may only advance this far on their own.
        let freeDistance = lost ? 2 : 3
        let end = min(words.count, currentWordIndex + window)
        for index in currentWordIndex..<end where Self.matches(spoken, words[index].normalized) {
            if index - currentWordIndex > freeDistance {
                // A lone word matching far ahead is weak evidence — common
                // words recur constantly, and recognizer noise during fast
                // reading must not race the script to the next occurrence.
                // Jumps need the previous spoken word to line up with the
                // preceding script word too…
                guard let previous, index > 0,
                      Self.matches(previous, words[index - 1].normalized) else { continue }
                // …and while lost (ad-libbing), the pair must include a
                // distinctive word: rambling is full of fragments like
                // "and the" that pair up with the script by accident.
                if lost && spoken.count < 4 && previous.count < 4 { continue }
            }
            advance(to: index)
            return
        }

        // Backward: after going quiet, speakers usually back up and re-read
        // the few words just before where they stopped. Re-anchor behind the
        // current position on two consecutive matches.
        if lost, let previous {
            let start = max(1, currentWordIndex - 10)
            for index in (start..<currentWordIndex).reversed()
            where Self.matches(spoken, words[index].normalized)
                && Self.matches(previous, words[index - 1].normalized) {
                advance(to: index)
                return
            }
        }
    }

    private func advance(to index: Int) {
        currentWordIndex = index + 1
        lastMatch = Date()
        status = .tracking
    }

    private static func matches(_ spoken: String, _ script: String) -> Bool {
        if spoken == script { return true }
        let length = max(spoken.count, script.count)
        guard min(spoken.count, script.count) >= 3, length >= 4 else { return false }
        let limit = length >= 7 ? 2 : 1
        return editDistance(spoken, script, limit: limit) <= limit
    }

    private static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a.unicodeScalars)
        let b = Array(b.unicodeScalars)
        if abs(a.count - b.count) > limit { return limit + 1 }
        var previous = Array(0...b.count)
        for (i, charA) in a.enumerated() {
            var current = [i + 1]
            current.reserveCapacity(b.count + 1)
            for (j, charB) in b.enumerated() {
                let cost = charA == charB ? 0 : 1
                current.append(min(previous[j] + cost, previous[j + 1] + 1, current[j] + 1))
            }
            if current.min()! > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }

    // MARK: - Watchdog

    /// Live recognition tasks can die silently — on-device tasks especially,
    /// during long sessions — and a dead task looks exactly like silence.
    /// If no result has arrived for a while, restart the task: during real
    /// silence the restart costs nothing, and after a stall it's the cure.
    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.shouldBeRunning else { return }
                if Date().timeIntervalSince(self.lastResultDate ?? .distantPast) > 8 {
                    self.beginTask()
                }
            }
        }
    }

    // MARK: - Tracking decay

    /// Drop back from .tracking to .listening when nothing has matched
    /// recently — the speaker paused or went off script.
    private func startDecayTimer() {
        decayTimer?.invalidate()
        decayTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.status == .tracking else { return }
                if let last = self.lastMatch, Date().timeIntervalSince(last) > 2.5 {
                    self.status = .listening
                }
            }
        }
    }
}
