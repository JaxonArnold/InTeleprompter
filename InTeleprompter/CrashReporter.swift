import Combine
import MessageUI
import MetricKit
import SwiftUI

/// Collects crash reports from MetricKit — Apple's on-device diagnostics,
/// delivered the next time the app launches after a crash — and keeps the
/// recent ones on the device. Nothing is sent anywhere on its own: the app
/// offers to share the newest report, and the user decides whether and how.
@MainActor
final class CrashReporter: NSObject, ObservableObject {
    static let shared = CrashReporter()

    /// Where crash reports are sent.
    static let supportEmail = "jack@centerlinewealth.com"

    /// The newest crash report the user hasn't been asked about yet.
    @Published private(set) var unsentReport: URL?

    nonisolated let directory: URL
    private let defaults: UserDefaults
    private static let handledKey = "handledCrashReport"
    nonisolated private static let reportsKept = 10

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    init(directory: URL = CrashReporter.defaultDirectory, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
        super.init()
    }

    func start() {
        MXMetricManager.shared.add(self)
        findUnsentReport()
    }

    /// The user shared the report or declined; don't ask about it again.
    func markHandled() {
        if let unsentReport {
            defaults.set(unsentReport.lastPathComponent, forKey: Self.handledKey)
        }
        unsentReport = nil
    }

    func findUnsentReport() {
        let handled = defaults.string(forKey: Self.handledKey) ?? ""
        let newest = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("InTeleprompter Crash ") }
            .max { $0.lastPathComponent < $1.lastPathComponent }
        unsentReport = newest.flatMap { $0.lastPathComponent > handled ? $0 : nil }
    }

    /// Saves reports as MetricKit's JSON, named by kind and time, keeping
    /// only the newest few.
    nonisolated static func store(_ reports: [(isCrash: Bool, date: Date, json: Data)], in directory: URL) {
        let files = FileManager.default
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        for report in reports {
            let name = "InTeleprompter \(report.isCrash ? "Crash" : "Diagnostics") \(formatter.string(from: report.date)).json"
            try? report.json.write(to: directory.appendingPathComponent(name), options: .atomic)
        }

        // Names end in a fixed-width timestamp, so its text sorts by time.
        let saved = ((try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent.suffix(24) > $1.lastPathComponent.suffix(24) }
        for old in saved.dropFirst(reportsKept) {
            try? files.removeItem(at: old)
        }
    }
}

extension CrashReporter {
    static let reportSubject = "InTeleprompter Pro crash report"

    /// Room for the user to add what happened, then the app version and
    /// device — the report's JSON has the rest.
    static var reportBody: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return """
        What were you doing when the app closed? (Optional)



        InTeleprompter \(version) (\(build)) · iOS \(UIDevice.current.systemVersion) · \(model)
        """
    }
}

extension CrashReporter: MXMetricManagerSubscriber {
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        Self.store(payloads.map {
            (isCrash: !($0.crashDiagnostics ?? []).isEmpty, date: $0.timeStampEnd, json: $0.jsonRepresentation())
        }, in: directory)
        Task { @MainActor in self.findUnsentReport() }
    }
}

/// Mail's compose sheet, addressed to support with the report attached.
/// Only for devices where `MFMailComposeViewController.canSendMail()`.
struct CrashReportMail: UIViewControllerRepresentable {
    let report: URL
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let mail = MFMailComposeViewController()
        mail.mailComposeDelegate = context.coordinator
        mail.setToRecipients([CrashReporter.supportEmail])
        mail.setSubject(CrashReporter.reportSubject)
        mail.setMessageBody(CrashReporter.reportBody, isHTML: false)
        if let data = try? Data(contentsOf: report) {
            mail.addAttachmentData(data, mimeType: "application/json", fileName: report.lastPathComponent)
        }
        return mail
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) {
            onFinish()
        }
    }
}

/// The system share sheet, for sending a file.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
