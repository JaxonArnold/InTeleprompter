import Foundation
import Testing
@testable import InTeleprompter

@MainActor
struct CrashReporterTests {

    private let day = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00:00 UTC

    private func makeReporter() -> (reporter: CrashReporter, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crash-test-" + UUID().uuidString, isDirectory: true)
        let defaults = UserDefaults(suiteName: "crash-test-" + UUID().uuidString)!
        return (CrashReporter(directory: directory, defaults: defaults), directory)
    }

    @Test func offersTheNewestCrashOnce() throws {
        let (reporter, directory) = makeReporter()
        defer { try? FileManager.default.removeItem(at: directory) }

        CrashReporter.store([
            (isCrash: true, date: day, json: Data(#"{"first":1}"#.utf8)),
            (isCrash: false, date: day.addingTimeInterval(60), json: Data("{}".utf8)),   // a hang, not a crash
            (isCrash: true, date: day.addingTimeInterval(30), json: Data(#"{"second":2}"#.utf8)),
        ], in: directory)
        reporter.findUnsentReport()
        let report = try #require(reporter.unsentReport)
        #expect(report.lastPathComponent == "InTeleprompter Crash 2027-01-15 08.00.30.json")
        #expect(try String(contentsOf: report, encoding: .utf8) == #"{"second":2}"#)

        reporter.markHandled()
        reporter.findUnsentReport()
        #expect(reporter.unsentReport == nil)

        // The next crash is offered again.
        CrashReporter.store([(isCrash: true, date: day.addingTimeInterval(120), json: Data("{}".utf8))],
                            in: directory)
        reporter.findUnsentReport()
        #expect(reporter.unsentReport?.lastPathComponent == "InTeleprompter Crash 2027-01-15 08.02.00.json")
    }

    @Test func keepsOnlyTheNewestReports() throws {
        let (_, directory) = makeReporter()
        defer { try? FileManager.default.removeItem(at: directory) }

        CrashReporter.store((0..<15).map {
            (isCrash: $0.isMultiple(of: 2), date: day.addingTimeInterval(Double($0)), json: Data("{}".utf8))
        }, in: directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted { $0.suffix(24) < $1.suffix(24) }
        #expect(names.count == 10)
        #expect(names.first?.hasSuffix("08.00.05.json") == true)
        #expect(names.last?.hasSuffix("08.00.14.json") == true)
    }
}

struct AudioLevelMeterTests {
    @Test func mapsDecibelsOntoTheMeter() {
        #expect(AudioLevelMeter.normalized(-80) == 0)
        #expect(AudioLevelMeter.normalized(-25) == 0.5)
        #expect(AudioLevelMeter.normalized(0) == 1)
        #expect(AudioLevelMeter.normalized(6) == 1)
    }
}
