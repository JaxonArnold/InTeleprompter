import Compression
import Foundation
import PDFKit
import UIKit   // NSAttributedString document-format initializers live here on iOS
import UniformTypeIdentifiers

/// Extracts plain script text from files (in-app picker, share extension)
/// and raw shared text. Everything happens on-device; unsupported files or
/// files with no extractable text surface a specific, actionable error.
///
/// Supported: .txt, .md, .rtf/.rtfd, .docx, .pdf — plus .gdoc, which is
/// detected and politely refused (it's a pointer, not a document).
enum ScriptImporter {

    struct ImportedScript {
        let title: String
        let text: String
    }

    // MARK: - Entry points

    static func load(from url: URL) throws -> ImportedScript {
        let text: String
        switch url.pathExtension.lowercased() {
        case "txt", "md", "markdown", "text":
            text = try loadPlainText(from: url)
        case "rtf", "rtfd":
            text = try loadRTF(from: url)
        case "docx":
            text = try DocxReader.text(from: url)
        case "pdf":
            text = try loadPDF(from: url)
        case "gdoc":
            throw googleDocError(from: url)
        default:
            throw ScriptImportError.unsupportedType(url.lastPathComponent)
        }
        return ImportedScript(title: title(from: url), text: text)
    }

    /// Text shared as a string — share sheet from Notes, Safari selections,
    /// or paste from the clipboard.
    static func load(text: String) throws -> ImportedScript {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ScriptImportError.emptyText(.generic) }
        return ImportedScript(title: title(fromText: trimmed), text: trimmed)
    }

    // MARK: - Titles

    private static func title(from url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Imported script" : name
    }

    private static func title(fromText text: String) -> String {
        let firstLine = text.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if firstLine.isEmpty { return "Pasted script" }
        return firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
    }

    // MARK: - Format loaders

    private static func loadPlainText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        for encoding in [String.Encoding.utf8, .utf16, .windowsCP1252] {
            if let text = String(data: data, encoding: encoding) {
                let normalized = text
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty { return normalized }
            }
        }
        throw ScriptImportError.emptyText(.generic)
    }

    private static func loadRTF(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else {
            throw ScriptImportError.unreadableFile
        }
        let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ScriptImportError.emptyText(.generic) }
        return text
    }

    private static func loadPDF(from url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw ScriptImportError.unreadableFile
        }
        let text = (document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ScriptImportError.emptyText(.scannedPDF) }
        return text
    }

    /// A .gdoc is a small JSON pointer ({url, doc_id, …}) written by Google
    /// Drive — it contains no document text, and the app makes no network
    /// calls. Surface the link so the UI can offer to open it.
    private static func googleDocError(from url: URL) -> ScriptImportError {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count < 64_000,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let link = dict["url"] as? String,
              let docURL = URL(string: link) else {
            return .googleDocShortcut(nil)
        }
        return .googleDocShortcut(docURL)
    }

    // MARK: - File-picker types

    /// Content types accepted by the in-app file picker. (.gdoc is included
    /// so selecting one produces the helpful guidance instead of a dead end.)
    static var pickerContentTypes: [UTType] {
        var types: [UTType] = [
            .plainText,      // .txt and .md (markdown conforms to plainText)
            .text,
            .rtf, .rtfd,
            .pdf,
        ]
        // Prefer system-declared types; fall back to extension-based lookups without requiring Info.plist declarations.
        if let docx = UTType(filenameExtension: "docx", conformingTo: .data) {
            types.append(docx)
        }
        if let markdown = UTType(filenameExtension: "md", conformingTo: .plainText) {
            types.append(markdown)
        }
        if let gdoc = UTType(filenameExtension: "gdoc", conformingTo: .data) {
            types.append(gdoc)
        }
        return types
    }
}

// MARK: - Errors

enum ScriptImportError: LocalizedError {
    case unreadableFile
    case emptyText(EmptyHint)
    case unsupportedType(String)
    /// A Google Drive shortcut — carries the doc link when it could be read.
    case googleDocShortcut(URL?)

    enum EmptyHint {
        case generic, scannedPDF
    }

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return "The file couldn't be read."
        case .emptyText(.generic):
            return "No text could be found in this file."
        case .emptyText(.scannedPDF):
            return "No text could be found in this PDF — it looks like a scan. Image-only PDFs need OCR before they can be imported."
        case .unsupportedType(let name):
            return "“\(name)” isn't a supported script file. Supported formats: PDF, Word (.docx), RTF, Markdown, and plain text."
        case .googleDocShortcut:
            return "This is a Google Docs shortcut — it points at the document but doesn't contain it.\n\nIn the Google Docs app, tap ⋯ → Share & export → Send a copy → Word (.docx), then choose InTeleprompter."
        }
    }
}

// MARK: - DOCX reader

/// Minimal reader for Word (.docx) scripts. iOS's NSAttributedString only
/// *appears* to read .docx — it actually returns the raw zip bytes as text —
/// so the container is unpacked here: word/document.xml is inflated and its
/// text runs stitched back into paragraphs.
enum DocxReader {

    static func text(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let xml = try ZipArchive.extract(named: "word/document.xml", from: data) else {
            // Not a zip, or no document part — not a real .docx.
            throw ScriptImportError.unreadableFile
        }
        let text = WordDocumentXMLExtractor.extract(from: xml)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ScriptImportError.emptyText(.generic) }
        return text
    }
}

/// Just enough ZIP to pull one file out of an OOXML container: central
/// directory walk, then stored or deflated payload (via Compression).
enum ZipArchive {

    enum ZipError: Error {
        case malformed
        case unsupportedCompression
    }

    static func extract(named wanted: String, from data: Data) throws -> Data? {
        // Locate the end-of-central-directory record (scans the last 64 KB,
        // the maximum comment size, for its PK\x05\x06 signature).
        guard data.count >= 22 else { return nil }
        let searchStart = max(0, data.count - 65_557)
        var eocd: Int?
        for i in stride(from: data.count - 22, through: searchStart, by: -1)
        where data[i] == 0x50 && data[i + 1] == 0x4B && data[i + 2] == 0x05 && data[i + 3] == 0x06 {
            eocd = i
            break
        }
        guard let eocdOffset = eocd else { return nil }

        let entryCount = Int(readUInt16(data, eocdOffset + 10))
        var cursor = Int(readUInt32(data, eocdOffset + 16))

        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count, readUInt32(data, cursor) == 0x0201_4B50 else {
                throw ZipError.malformed
            }
            let method = readUInt16(data, cursor + 10)
            let compressedSize = Int(readUInt32(data, cursor + 20))
            let uncompressedSize = Int(readUInt32(data, cursor + 24))
            let nameLength = Int(readUInt16(data, cursor + 28))
            let extraLength = Int(readUInt16(data, cursor + 30))
            let commentLength = Int(readUInt16(data, cursor + 32))
            let localHeaderOffset = Int(readUInt32(data, cursor + 42))
            let nameRange = cursor + 46 ..< cursor + 46 + nameLength
            guard nameRange.upperBound <= data.count else { throw ZipError.malformed }
            let name = String(data: data.subdata(in: nameRange), encoding: .utf8) ?? ""

            if name == wanted {
                return try extractEntry(
                    from: data,
                    localHeaderOffset: localHeaderOffset,
                    method: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize
                )
            }
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return nil
    }

    private static func extractEntry(from data: Data,
                                     localHeaderOffset: Int,
                                     method: UInt16,
                                     compressedSize: Int,
                                     uncompressedSize: Int) throws -> Data {
        guard localHeaderOffset + 30 <= data.count,
              readUInt32(data, localHeaderOffset) == 0x0403_4B50 else {
            throw ZipError.malformed
        }
        let nameLength = Int(readUInt16(data, localHeaderOffset + 26))
        let extraLength = Int(readUInt16(data, localHeaderOffset + 28))
        let dataStart = localHeaderOffset + 30 + nameLength + extraLength
        guard dataStart + compressedSize <= data.count else { throw ZipError.malformed }
        let payload = data.subdata(in: dataStart ..< dataStart + compressedSize)

        switch method {
        case 0:  // stored
            return payload
        case 8:  // deflate (raw; Compression's zlib codec decodes it)
            return try inflate(payload, expectedSize: uncompressedSize)
        default:
            throw ZipError.unsupportedCompression
        }
    }

    private static func inflate(_ source: Data, expectedSize: Int) throws -> Data {
        var destination = Data(count: expectedSize)
        let written: Int = destination.withUnsafeMutableBytes { dstPtr in
            source.withUnsafeBytes { srcPtr in
                compression_decode_buffer(
                    dstPtr.baseAddress!, expectedSize,
                    srcPtr.baseAddress!, source.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { throw ZipError.malformed }
        return destination
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}

/// Pulls the text out of word/document.xml: characters inside <w:t> runs,
/// a tab for <w:tab>, a newline for <w:br>, and a newline per </w:p>.
/// Prefix-agnostic — the "w" namespace prefix is conventional, not required.
final class WordDocumentXMLExtractor: NSObject, XMLParserDelegate {

    static func extract(from data: Data) -> String {
        let extractor = WordDocumentXMLExtractor()
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        parser.parse()
        return extractor.text
    }

    private var text = ""
    private var inTextRun = false

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        switch localName(of: elementName) {
        case "t":
            inTextRun = true
        case "tab":
            if inTextRun { text.append("\t") }
        case "br", "cr":
            text.append("\n")
        default:
            break
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        switch localName(of: elementName) {
        case "t":
            inTextRun = false
        case "p":
            if !text.hasSuffix("\n") { text.append("\n") }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // instrText (field instructions) is skipped — only real text runs.
        if inTextRun { text.append(string) }
    }

    private func localName(of element: String) -> String {
        element.split(separator: ":").last.map(String.init) ?? element
    }
}
