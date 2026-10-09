//
//  InTeleprompterTests.swift
//  InTeleprompterTests
//
//  Created by Jack Arnold on 6/11/26.
//

import Foundation
import Testing
@testable import InTeleprompter

// MARK: - Tokenizer

struct ScriptTokenizerTests {

    @Test func tokenizesWordsAndStripsPunctuation() {
        let words = ScriptTokenizer.words(in: "Tap the red button — it's a 3-second countdown!")
        #expect(words.map(\.normalized) ==
                ["tap", "the", "red", "button", "its", "a", "3", "second", "countdown"])
    }

    @Test func recordsOriginalRanges() {
        let text = "Hello brave world"
        let words = ScriptTokenizer.words(in: text)
        let nsText = text as NSString
        #expect(words.map { nsText.substring(with: $0.range) } == ["Hello", "brave", "world"])
    }

    @Test func normalizeLowercasesAndStripsSymbols() {
        #expect(ScriptTokenizer.normalize("Hello,") == "hello")
        #expect(ScriptTokenizer.normalize("it's") == "its")
        #expect(ScriptTokenizer.normalize("—") == "")
    }
}

// MARK: - Voice tracker matching

@MainActor
struct SpeechScriptTrackerTests {

    /// Word indices for reference:
    /// 0 welcome 1 back 2 to 3 the 4 show 5 today 6 we 7 are 8 going 9 to
    /// 10 talk 11 about 12 the 13 future 14 of 15 the 16 creator 17 economy
    /// 18 and 19 the 20 tools 21 that 22 make 23 it 24 possible
    private static let script = """
        Welcome back to the show today we are going to talk about the future \
        of the creator economy and the tools that make it possible
        """

    private func makeTracker() -> SpeechScriptTracker {
        SpeechScriptTracker(scriptText: Self.script)
    }

    private func say(_ tracker: SpeechScriptTracker, _ tokens: [String]) {
        for token in tokens {
            tracker.match(ScriptTokenizer.normalize(token))
        }
    }

    /// Puts the tracker in the "lost" state, as if nothing matched for a while.
    private func goSilent(_ tracker: SpeechScriptTracker) {
        tracker.lastMatch = Date(timeIntervalSinceNow: -10)
    }

    // MARK: Normal reading

    @Test func normalReadingTracksWordByWord() {
        let tracker = makeTracker()
        say(tracker, ["welcome", "back", "to", "the", "show", "today"])
        #expect(tracker.currentWordIndex == 6)
    }

    @Test func fuzzyMatchesInflectedWords() {
        let tracker = makeTracker()
        say(tracker, ["welcome", "back", "to", "the", "show", "today", "we", "are",
                      "going", "to", "talk", "about", "the", "future", "of", "the",
                      "creator", "economy", "and", "the"])
        say(tracker, ["tool"])   // script says "tools"
        #expect(tracker.currentWordIndex == 21)
    }

    // MARK: Fast reading / recognizer noise

    @Test func strayCommonWordCannotJumpFarAhead() {
        let tracker = makeTracker()
        say(tracker, ["welcome", "back", "to", "the", "show", "today"])
        // "the" recurs at index 12 — a lone short word must not race there.
        say(tracker, ["the"])
        #expect(tracker.currentWordIndex == 6)
        // Reading continues correctly afterward.
        say(tracker, ["we", "are", "going"])
        #expect(tracker.currentWordIndex == 9)
    }

    // MARK: Going off script

    @Test func offScriptRamblingDoesNotDrift() {
        let tracker = makeTracker()
        say(tracker, ["welcome", "back", "to", "the", "show", "today", "we", "are", "going"])
        goSilent(tracker)
        // Contains an "and the" pair that exists later in the script (18–19);
        // the distinctiveness rule must block that accidental anchor.
        say(tracker, ["yeah", "so", "and", "the", "thing", "is", "um", "like",
                      "and", "the", "whatever"])
        #expect(tracker.currentWordIndex == 9)
    }

    /// Regression: going off script before the first word matched — at the
    /// start of a take, or right after rewinding — crashed the app.
    @Test func offScriptSpeechBeforeTheFirstWordIsIgnored() {
        let tracker = makeTracker()
        say(tracker, ["okay", "um", "so", "we're", "rolling"])
        #expect(tracker.currentWordIndex == 0)
        say(tracker, ["welcome", "back"])
        #expect(tracker.currentWordIndex == 2)

        tracker.seek(to: 0)   // rewind
        say(tracker, ["hang", "on", "one", "more", "time"])
        #expect(tracker.currentWordIndex == 0)
    }

    @Test func resumesAtTheExactStopWordAfterSilence() {
        let tracker = makeTracker()
        say(tracker, ["welcome", "back", "to", "the", "show"])
        goSilent(tracker)
        say(tracker, ["today", "we"])
        #expect(tracker.currentWordIndex == 7)
    }

    @Test func resumesByRereadingBeforeTheStopPoint() {
        let tracker = makeTracker()
        say(tracker, ["welcome", "back", "to", "the", "show", "today", "we", "are", "going"])
        goSilent(tracker)
        say(tracker, ["nope", "lost", "my", "thread"])   // off-script filler
        // Speaker backs up two words and re-reads through the stop point.
        say(tracker, ["are", "going", "to", "talk"])
        #expect(tracker.currentWordIndex == 11)
    }

    @Test func skipAheadWhileLostLocksOnBySecondWord() {
        let tracker = makeTracker()
        say(tracker, ["welcome", "back", "to", "the", "show", "today", "we"])
        goSilent(tracker)
        say(tracker, ["the", "creator", "economy"])
        #expect(tracker.currentWordIndex == 18)
    }

    // MARK: Transcript revision handling

    @Test func growingPartialsAreIdempotent() {
        let tracker = makeTracker()
        tracker.handleTranscriptionUpdate(["Welcome"])
        tracker.handleTranscriptionUpdate(["Welcome", "back"])
        tracker.handleTranscriptionUpdate(["Welcome", "back", "to", "the", "show"])
        #expect(tracker.currentWordIndex == 5)
        // The same hypothesis delivered again must not advance anything.
        tracker.handleTranscriptionUpdate(["Welcome", "back", "to", "the", "show"])
        #expect(tracker.currentWordIndex == 5)
    }

    @Test func rechunkShrinkDoesNotSkipFollowingWords() {
        let tracker = makeTracker()
        tracker.handleTranscriptionUpdate(["Welcome", "back", "to", "the", "show"])
        // At a pause the recognizer rewrites its tail, shrinking the list…
        tracker.handleTranscriptionUpdate(["Welcome", "back", "to"])
        // …and the words spoken next must still be matched.
        tracker.handleTranscriptionUpdate(["Welcome", "back", "to", "today", "we"])
        #expect(tracker.currentWordIndex == 7)
        tracker.handleTranscriptionUpdate(["Welcome", "back", "to", "today", "we", "are", "going"])
        #expect(tracker.currentWordIndex == 9)
    }

    // MARK: Seeking

    @Test func seekClampsToScriptBounds() {
        let tracker = makeTracker()
        tracker.seek(to: 999)
        #expect(tracker.currentWordIndex == tracker.words.count - 1)
        tracker.seek(to: -5)
        #expect(tracker.currentWordIndex == 0)
    }

    @Test func wordRangesStayAlignedWithWords() {
        let tracker = makeTracker()
        #expect(tracker.wordRanges.count == tracker.words.count)
        #expect(tracker.wordRanges == tracker.words.map(\.range))
    }
}
