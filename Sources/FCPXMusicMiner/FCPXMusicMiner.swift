import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Foundation

private let audioExtensions: Set<String> = [
    "mp3", "wav", "wave", "aif", "aiff", "m4a", "aac", "flac", "caf", "ogg"
]

private let likelyMusicExtensions: Set<String> = [
    "mp3", "m4a", "aac", "aif", "aiff", "flac"
]

private let musicPathWords = [
    "artlist", "musicbed", "epidemic", "soundstripe", "music", "muziek",
    "songs", "tracks", "audio network", "audionetwork", "premiumbeat"
]

private let recorderWords = [
    "zoom", "tascam", "rode", "lav", "lavalier", "wireless", "mic", "microfoon",
    "recorder", "ceremony", "ceremonie", "speech", "speeches", "toespraak",
    "geloften", "vows", "interview", "h1n", "h2n", "h4n", "h5", "h6",
    "dr-10", "dr10", "tentacle", "instamic"
]

private let ignoredProjectFolders: Set<String> = [
    "Original Media", "Transcoded Media", "Render Files", "Analysis Files",
    "Shared Items", "Motion Templates", "Backups", ".fcpcache"
]

enum MatchConfidence: Int, Comparable {
    case low = 0
    case medium = 1
    case high = 2

    static func < (lhs: MatchConfidence, rhs: MatchConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .low: return "laag"
        case .medium: return "middel"
        case .high: return "hoog"
        }
    }
}

struct LibraryEntry: Identifiable, Hashable {
    let id = UUID()
    let url: URL

    var name: String { url.deletingPathExtension().lastPathComponent }
    var volumeRoot: URL { VolumeHelper.rootURL(for: url) }
}

struct TrackMatch: Identifiable, Hashable {
    let id = UUID()
    let sourceURL: URL
    let displayName: String
    let normalizedKey: String
    let confidence: MatchConfidence
}

struct ProjectScan: Identifiable, Hashable {
    let id = UUID()
    let libraryURL: URL
    let eventName: String
    let projectName: String
    let databaseURL: URL
    let tracks: [TrackMatch]

    var libraryName: String {
        libraryURL.deletingPathExtension().lastPathComponent
    }

    var volumeRoot: URL {
        VolumeHelper.rootURL(for: libraryURL)
    }

    var family: String {
        ProjectVersion.family(for: projectName)
    }

    var versionHint: String {
        ProjectVersion.hint(for: projectName)
    }

    var likelyMusicCount: Int {
        tracks.filter { $0.confidence >= .medium }.count
    }
}

struct ExportResult {
    let volumeRoot: URL
    let outputURL: URL
    let copiedTracks: Int
    let selectedProjects: Int
}

enum VolumeHelper {
    static func rootURL(for url: URL) -> URL {
        let parts = url.standardizedFileURL.pathComponents
        if parts.count >= 3, parts[1] == "Volumes" {
            return URL(fileURLWithPath: "/Volumes").appendingPathComponent(parts[2], isDirectory: true)
        }
        return URL(fileURLWithPath: "/", isDirectory: true)
    }
}

enum ProjectVersion {
    static func family(for name: String) -> String {
        var value = name.lowercased()
        let patterns = [
            #"\b(?:v|versie|version)\s*0*\d+\b"#,
            #"\brev(?:ision)?\s*0*\d+\b"#,
            #"\b(final|definitief|def|copy|kopie|old|oud|backup|test|nieuw|new)\b"#
        ]

        for pattern in patterns {
            value = value.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }

        value = value.replacingOccurrences(
            of: #"[_\-–—]+"#,
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hint(for name: String) -> String {
        let lower = name.lowercased()
        var hints: [String] = []

        if let number = firstCapture(in: lower, pattern: #"\b(?:v|versie|version)\s*0*(\d+)\b"#) {
            hints.append("v\(number)")
        }
        if lower.range(of: #"\b(final|definitief|def)\b"#, options: .regularExpression) != nil {
            hints.append("final")
        }
        if lower.range(of: #"\b(copy|kopie)\b"#, options: .regularExpression) != nil {
            hints.append("kopie")
        }
        if lower.range(of: #"\b(old|oud|backup|test)\b"#, options: .regularExpression) != nil {
            hints.append("oud/test")
        }

        return hints.joined(separator: ", ")
    }

    static func score(for name: String) -> (Int, Int, Int, String) {
        let lower = name.lowercased()
        let final = lower.range(of: #"\b(final|definitief|def)\b"#, options: .regularExpression) == nil ? 0 : 1
        let old = lower.range(of: #"\b(old|oud|backup|test|copy|kopie)\b"#, options: .regularExpression) == nil ? 0 : 1
        let version = Int(firstCapture(in: lower, pattern: #"\b(?:v|versie|version)\s*0*(\d+)\b"#) ?? "0") ?? 0
        return (final, version, -old, lower)
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound
        else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}

enum BundleScanner {
    static func scan(libraries: [LibraryEntry]) -> [ProjectScan] {
        libraries.flatMap { scan(library: $0.url) }
    }

    private static func scan(library: URL) -> [ProjectScan] {
        let fm = FileManager.default
        guard let topLevel = try? fm.contentsOfDirectory(
            at: library,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var projects: [ProjectScan] = []

        for eventURL in topLevel {
            guard isDirectory(eventURL),
                  fm.fileExists(atPath: eventURL.appendingPathComponent("CurrentVersion.fcpevent").path)
            else { continue }

            let candidates = audioCandidates(in: eventURL)
            guard let children = try? fm.contentsOfDirectory(
                at: eventURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for projectURL in children {
                guard isDirectory(projectURL),
                      !ignoredProjectFolders.contains(projectURL.lastPathComponent)
                else { continue }

                let dbURL = projectURL.appendingPathComponent("CurrentVersion.fcpevent")
                guard fm.fileExists(atPath: dbURL.path) else { continue }

                let matches = matchesInProject(databaseURL: dbURL, candidates: candidates)
                projects.append(
                    ProjectScan(
                        libraryURL: library,
                        eventName: eventURL.lastPathComponent,
                        projectName: projectURL.lastPathComponent,
                        databaseURL: dbURL,
                        tracks: matches
                    )
                )
            }
        }

        return projects
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func audioCandidates(in eventURL: URL) -> [URL] {
        let mediaURL = eventURL.appendingPathComponent("Original Media", isDirectory: true)
        guard FileManager.default.fileExists(atPath: mediaURL.path) else { return [] }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: mediaURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [URL] = []
        var seen: Set<String> = []

        for case let item as URL in enumerator {
            let resolved = item.resolvingSymlinksInPath()
            let ext = (resolved.pathExtension.isEmpty ? item.pathExtension : resolved.pathExtension).lowercased()
            guard audioExtensions.contains(ext) else { continue }

            let chosen = FileManager.default.fileExists(atPath: resolved.path) ? resolved : item
            if seen.insert(chosen.path).inserted {
                result.append(chosen)
            }
        }

        return result
    }

    private enum PlaybackState {
        case active
        case disabled
        case unknown
    }

    private struct SQLiteColumn {
        let name: String
        let loweredName: String
    }

    private struct SQLiteTable {
        let name: String
        let columns: [SQLiteColumn]

        var stateColumns: [SQLiteColumn] {
            columns.filter { column in
                let n = column.loweredName
                return n.contains("enable")
                    || n.contains("disable")
                    || n.contains("active")
                    || n.contains("audible")
                    || n.contains("mute")
            }
        }
    }

    private static func matchesInProject(databaseURL: URL, candidates: [URL]) -> [TrackMatch] {
        guard let data = try? Data(contentsOf: databaseURL, options: [.mappedIfSafe]) else {
            return []
        }

        // Load the schema once per project. We still use the fast raw database scan
        // to discover references, then consult SQLite only for tracks that were found.
        let tables = sqliteTables(in: databaseURL)

        var result: [TrackMatch] = []
        var seen: Set<String> = []

        for candidate in candidates {
            let fileName = candidate.lastPathComponent
            let stem = candidate.deletingPathExtension().lastPathComponent

            let found = contains(text: fileName, in: data) || contains(text: stem, in: data)
            guard found else { continue }

            let key = normalizedTrackKey(fileName)
            guard seen.insert(key).inserted else { continue }

            // Final Cut can keep old/disabled clips in the project database.
            // Skip a track only when SQLite gives us explicit evidence that all
            // matching timeline/component rows are disabled or muted.
            let state = playbackState(
                databaseURL: databaseURL,
                tables: tables,
                fileName: fileName,
                stem: stem
            )
            guard state != .disabled else { continue }

            result.append(
                TrackMatch(
                    sourceURL: candidate,
                    displayName: fileName,
                    normalizedKey: key,
                    confidence: confidence(for: candidate)
                )
            )
        }

        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func sqliteTables(in databaseURL: URL) -> [SQLiteTable] {
        guard FileManager.default.fileExists(atPath: "/usr/bin/sqlite3") else { return [] }

        let sql = "SELECT name, sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND sql IS NOT NULL;"
        guard let rows = sqliteJSON(databaseURL: databaseURL, sql: sql) else { return [] }

        var result: [SQLiteTable] = []

        for row in rows {
            guard let tableName = row["name"] as? String,
                  let createSQL = row["sql"] as? String
            else { continue }

            let columns = parseColumnNames(fromCreateSQL: createSQL).map {
                SQLiteColumn(name: $0, loweredName: $0.lowercased())
            }

            if !columns.isEmpty {
                result.append(SQLiteTable(name: tableName, columns: columns))
            }
        }

        return result
    }

    private static func parseColumnNames(fromCreateSQL sql: String) -> [String] {
        guard let open = sql.firstIndex(of: "("),
              let close = sql.lastIndex(of: ")"),
              open < close
        else { return [] }

        let body = String(sql[sql.index(after: open)..<close])
        let parts = splitSQLColumns(body)
        var columns: [String] = []

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = trimmed.uppercased()

            if upper.hasPrefix("PRIMARY ")
                || upper.hasPrefix("UNIQUE ")
                || upper.hasPrefix("CONSTRAINT ")
                || upper.hasPrefix("FOREIGN ")
                || upper.hasPrefix("CHECK ")
            {
                continue
            }

            if trimmed.hasPrefix("\"") {
                let rest = trimmed.dropFirst()
                if let quote = rest.firstIndex(of: "\"") {
                    columns.append(String(rest[..<quote]))
                }
            } else if trimmed.hasPrefix("[") {
                let rest = trimmed.dropFirst()
                if let bracket = rest.firstIndex(of: "]") {
                    columns.append(String(rest[..<bracket]))
                }
            } else if let token = trimmed.split(whereSeparator: { $0.isWhitespace }).first {
                columns.append(String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\`")))
            }
        }

        return columns
    }

    private static func splitSQLColumns(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        var inSingleQuote = false
        var inDoubleQuote = false

        for ch in value {
            if ch == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
            } else if ch == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
            } else if !inSingleQuote && !inDoubleQuote {
                if ch == "(" { depth += 1 }
                if ch == ")" { depth = max(0, depth - 1) }
                if ch == "," && depth == 0 {
                    result.append(current)
                    current = ""
                    continue
                }
            }
            current.append(ch)
        }

        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private static func playbackState(
        databaseURL: URL,
        tables: [SQLiteTable],
        fileName: String,
        stem: String
    ) -> PlaybackState {
        guard !tables.isEmpty else { return .unknown }

        var sawDisabled = false
        var sawActive = false

        for table in tables {
            let stateColumns = table.stateColumns
            guard !stateColumns.isEmpty else { continue }

            // Searching every column is intentional: FCP may store the media reference
            // in an opaque text/blob field while the enabled flag sits in the same row.
            let searchable = table.columns.prefix(80)
            guard !searchable.isEmpty else { continue }

            let fileLiteral = sqlString(fileName.lowercased())
            let stemLiteral = sqlString(stem.lowercased())
            let whereParts = searchable.map { column in
                let q = quoteIdentifier(column.name)
                return "(instr(lower(CAST(\(q) AS TEXT)), \(fileLiteral)) > 0 OR instr(lower(CAST(\(q) AS TEXT)), \(stemLiteral)) > 0)"
            }

            let selectedStateColumns = stateColumns.map { quoteIdentifier($0.name) }.joined(separator: ", ")
            let sql = "SELECT \(selectedStateColumns) FROM \(quoteIdentifier(table.name)) WHERE \(whereParts.joined(separator: " OR ")) LIMIT 50;"

            guard let rows = sqliteJSON(databaseURL: databaseURL, sql: sql) else { continue }

            for row in rows {
                var rowDisabled = false
                var rowActive = false

                for column in stateColumns {
                    guard let raw = row[column.name] else { continue }
                    let truth = sqliteTruth(raw)
                    guard let truth else { continue }

                    let n = column.loweredName
                    if n.contains("disable") || n.contains("mute") {
                        if truth { rowDisabled = true }
                    } else if n.contains("enable") || n.contains("active") || n.contains("audible") {
                        if truth {
                            rowActive = true
                        } else {
                            rowDisabled = true
                        }
                    }
                }

                if rowActive { sawActive = true }
                if rowDisabled { sawDisabled = true }
            }
        }

        // If a song has both an old disabled instance and a live active instance,
        // it still belongs in the project.
        if sawActive { return .active }
        if sawDisabled { return .disabled }
        return .unknown
    }

    private static func sqliteJSON(databaseURL: URL, sql: String) -> [[String: Any]]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", databaseURL.path, sql]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty,
                  let object = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else {
                return []
            }
            return object
        } catch {
            return nil
        }
    }

    private static func sqliteTruth(_ value: Any) -> Bool? {
        if let number = value as? NSNumber {
            return number.doubleValue != 0
        }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on", "enabled", "active":
                return true
            case "0", "false", "no", "off", "disabled", "inactive", "":
                return false
            default:
                if let number = Double(string) {
                    return number != 0
                }
            }
        }
        return nil
    }

    private static func quoteIdentifier(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func sqlString(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func contains(text: String, in data: Data) -> Bool {
        if let utf8 = text.data(using: .utf8), data.range(of: utf8) != nil {
            return true
        }
        if let utf16 = text.data(using: .utf16LittleEndian), data.range(of: utf16) != nil {
            return true
        }
        return false
    }

    private static func confidence(for url: URL) -> MatchConfidence {
        let full = url.path.lowercased()
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()

        if musicPathWords.contains(where: { full.contains($0) }) {
            return .high
        }
        if recorderWords.contains(where: { name.contains($0) }) {
            return .low
        }
        if likelyMusicExtensions.contains(ext) {
            return .medium
        }
        return .medium
    }

    private static func normalizedTrackKey(_ name: String) -> String {
        var stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent.lowercased()
        stem = stem.replacingOccurrences(
            of: #"\s+\(\d+\)$"#,
            with: "",
            options: .regularExpression
        )
        stem = stem.replacingOccurrences(
            of: #"\s+-\s+copy(?:\s+\d+)?$"#,
            with: "",
            options: .regularExpression
        )
        stem = stem.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return stem.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum OutputWriter {
    private struct Aggregate {
        var displayName: String
        var sources: [URL]
        var projectIDs: Set<UUID>
        var confidence: MatchConfidence
    }

    static func write(projects: [ProjectScan]) throws -> [ExportResult] {
        let groups = Dictionary(grouping: projects) { $0.volumeRoot.standardizedFileURL.path }
        var results: [ExportResult] = []

        for (_, volumeProjects) in groups {
            guard let first = volumeProjects.first else { continue }
            let volumeRoot = first.volumeRoot
            let output = volumeRoot.appendingPathComponent("FCPXMusicMiner", isDirectory: true)

            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

            let mostUsed = output.appendingPathComponent("00 - Meest gebruikt", isDirectory: true)
            let unknown = output.appendingPathComponent("04 - Positie onbekend", isDirectory: true)
            let report = output.appendingPathComponent("_Rapport", isDirectory: true)

            for folder in [mostUsed, unknown, report] {
                if FileManager.default.fileExists(atPath: folder.path) {
                    try? FileManager.default.removeItem(at: folder)
                }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }

            var aggregates: [String: Aggregate] = [:]

            for project in volumeProjects {
                for track in project.tracks where track.confidence >= .medium {
                    var item = aggregates[track.normalizedKey] ?? Aggregate(
                        displayName: track.displayName,
                        sources: [],
                        projectIDs: [],
                        confidence: track.confidence
                    )
                    item.projectIDs.insert(project.id)
                    item.confidence = max(item.confidence, track.confidence)
                    if !item.sources.contains(track.sourceURL) {
                        item.sources.append(track.sourceURL)
                    }
                    aggregates[track.normalizedKey] = item
                }
            }

            let ranked = aggregates.values.sorted {
                if $0.projectIDs.count != $1.projectIDs.count {
                    return $0.projectIDs.count > $1.projectIDs.count
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }

            var copied = 0
            var csv = "Rang;Track;Projecten;Confidence;Bron\n"

            for (index, aggregate) in ranked.enumerated() {
                guard let source = aggregate.sources.first(where: {
                    FileManager.default.fileExists(atPath: $0.path)
                }) else { continue }

                let rank = index + 1
                let count = aggregate.projectIDs.count
                let base = safeName(source.deletingPathExtension().lastPathComponent)
                let fileName = String(format: "%03d__%02dx__%@.%@", rank, count, base, source.pathExtension)

                let mainDestination = mostUsed.appendingPathComponent(fileName)
                let unknownDestination = unknown.appendingPathComponent(fileName)

                try copyReplacing(source: source, destination: mainDestination)
                try copyReplacing(source: source, destination: unknownDestination)
                copied += 1

                csv += "\(rank);\(csvEscape(aggregate.displayName));\(count);\(aggregate.confidence.label);\(csvEscape(source.path))\n"
            }

            try csv.write(
                to: report.appendingPathComponent("tracks_overzicht.csv"),
                atomically: true,
                encoding: .utf8
            )

            var projectCSV = "Library;Event;Project;Tracks gevonden;Versie-hint;Database\n"
            for project in volumeProjects.sorted(by: {
                $0.projectName.localizedCaseInsensitiveCompare($1.projectName) == .orderedAscending
            }) {
                projectCSV += [
                    csvEscape(project.libraryName),
                    csvEscape(project.eventName),
                    csvEscape(project.projectName),
                    String(project.likelyMusicCount),
                    csvEscape(project.versionHint),
                    csvEscape(project.databaseURL.path)
                ].joined(separator: ";") + "\n"
            }

            try projectCSV.write(
                to: report.appendingPathComponent("geselecteerde_projecten.csv"),
                atomically: true,
                encoding: .utf8
            )

            let note = """
            FCPX Music Miner

            Deze map is gegenereerd uit \(volumeProjects.count) geselecteerde Final Cut Pro-projecten.

            BELANGRIJK:
            De app leest .fcpbundle libraries read-only.
            De interne CurrentVersion.fcpevent database is wel SQLite, maar Apple's schema is niet publiek gedocumenteerd.
            Daarom is de directe bundle-scan geschikt voor projectniveau + gebruikstelling, maar wordt timelinevolgorde
            nog niet als opener/midden/einde gepresenteerd totdat die volgorde betrouwbaar kan worden bepaald.

            Bronvolume: \(volumeRoot.path)
            """
            try note.write(
                to: report.appendingPathComponent("LEESMIJ.txt"),
                atomically: true,
                encoding: .utf8
            )

            results.append(
                ExportResult(
                    volumeRoot: volumeRoot,
                    outputURL: output,
                    copiedTracks: copied,
                    selectedProjects: volumeProjects.count
                )
            )
        }

        return results.sorted { $0.volumeRoot.path < $1.volumeRoot.path }
    }

    private static func copyReplacing(source: URL, destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }

    private static func safeName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\n\r\t")
        return value.components(separatedBy: invalid).joined(separator: "-")
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(";") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}

@main
struct FCPXMusicMinerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 650)
        }
        .windowStyle(.titleBar)
    }
}

struct ContentView: View {
    @State private var libraries: [LibraryEntry] = []
    @State private var projects: [ProjectScan] = []
    @State private var selectedProjectIDs: Set<UUID> = []
    @State private var scanning = false
    @State private var exporting = false
    @State private var search = ""
    @State private var status = "Voeg één of meer Final Cut Pro libraries toe."
    @State private var results: [ExportResult] = []
    @State private var errorMessage: String?

    private var filteredProjects: [ProjectScan] {
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return projects
        }
        let needle = search.lowercased()
        return projects.filter {
            $0.projectName.lowercased().contains(needle)
            || $0.libraryName.lowercased().contains(needle)
            || $0.eventName.lowercased().contains(needle)
        }
    }

    private var duplicateFamilies: Set<String> {
        let groups = Dictionary(grouping: projects) {
            $0.libraryURL.path + "::" + $0.family
        }
        return Set(groups.filter { $0.value.count > 1 }.map(\.key))
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if projects.isEmpty {
                emptyState
            } else {
                projectSelection
            }

            Divider()
            footer
        }
        .alert("Fout", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("FCPX Music Miner")
                        .font(.system(size: 28, weight: .bold))
                    Text("Vind je meest gebruikte trouwfilm-muziek per Final Cut-project.")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Voeg libraries toe…") {
                    chooseLibraries()
                }
                .buttonStyle(.bordered)

                Button("Voeg map toe…") {
                    chooseFolder()
                }
                .buttonStyle(.bordered)

                Button(scanning ? "Scannen…" : "Scan alles") {
                    scanAll()
                }
                .buttonStyle(.borderedProminent)
                .disabled(libraries.isEmpty || scanning)
            }

            if !libraries.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(libraries) { library in
                            HStack(spacing: 6) {
                                Image(systemName: "shippingbox.fill")
                                Text(library.name)
                                Text("→ \(library.volumeRoot.path)/FCPXMusicMiner")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.10))
                            .clipShape(Capsule())
                        }
                    }
                }
            }

            HStack {
                ProgressView()
                    .controlSize(.small)
                    .opacity(scanning || exporting ? 1 : 0)
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)

            Text("Batchscan van .fcpbundle libraries")
                .font(.title2.bold())

            Text("Selecteer meerdere libraries of één map met libraries.\nDaarna krijg je alle projecten in één lijst en vink je oude versies uit.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Text("De app wijzigt nooit iets in een Final Cut-library. Expliciet uitgeschakelde/muted tracks worden overgeslagen.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var projectSelection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button("Alles") {
                    selectedProjectIDs = Set(projects.map(\.id))
                }

                Button("Niets") {
                    selectedProjectIDs.removeAll()
                }

                Button("Waarschijnlijk nieuwste versie") {
                    selectLikelyLatest()
                }

                Spacer()

                Text("\(selectedProjectIDs.count) van \(projects.count) geselecteerd")
                    .font(.callout.weight(.semibold))

                TextField("Zoek project, event of library", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
            }
            .padding(14)

            List(filteredProjects) { project in
                let familyKey = project.libraryURL.path + "::" + project.family
                let duplicate = duplicateFamilies.contains(familyKey)

                HStack(spacing: 12) {
                    Toggle("", isOn: Binding(
                        get: { selectedProjectIDs.contains(project.id) },
                        set: { value in
                            if value {
                                selectedProjectIDs.insert(project.id)
                            } else {
                                selectedProjectIDs.remove(project.id)
                            }
                        }
                    ))
                    .labelsHidden()

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(project.projectName)
                                .fontWeight(.semibold)

                            if duplicate {
                                Text("MOGELIJKE VERSIE")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.orange.opacity(0.18))
                                    .clipShape(Capsule())
                            }

                            if !project.versionHint.isEmpty {
                                Text(project.versionHint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text("\(project.libraryName) › \(project.eventName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(project.likelyMusicCount) tracks")
                            .fontWeight(.medium)
                        Text(project.volumeRoot.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private var footer: some View {
        HStack {
            if !results.isEmpty {
                Menu("Open resultaat") {
                    ForEach(results.indices, id: \.self) { index in
                        Button(results[index].outputURL.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([results[index].outputURL])
                        }
                    }
                }
            }

            Spacer()

            Text("Output: /Volumes/[schijf]/FCPXMusicMiner")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(exporting ? "Bezig…" : "Maak muziekbibliotheek") {
                exportSelected()
            }
            .buttonStyle(.borderedProminent)
            .disabled(projects.isEmpty || selectedProjectIDs.isEmpty || exporting)
        }
        .padding(16)
    }

    private func chooseLibraries() {
        let panel = NSOpenPanel()
        panel.title = "Kies één of meer .fcpbundle libraries"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        if let type = UTType(filenameExtension: "fcpbundle") {
            panel.allowedContentTypes = [type]
        }

        if panel.runModal() == .OK {
            addLibraries(panel.urls)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Kies een map met .fcpbundle libraries"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        if panel.runModal() == .OK, let root = panel.url {
            let found = findBundles(in: root)
            addLibraries(found)
        }
    }

    private func findBundles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == "fcpbundle" {
                result.append(url)
                enumerator.skipDescendants()
            }
        }
        return result
    }

    private func addLibraries(_ urls: [URL]) {
        let valid = urls.filter { $0.pathExtension.lowercased() == "fcpbundle" }
        var existing = Set(libraries.map { $0.url.standardizedFileURL.path })

        for url in valid {
            if existing.insert(url.standardizedFileURL.path).inserted {
                libraries.append(LibraryEntry(url: url))
            }
        }

        projects = []
        selectedProjectIDs = []
        results = []
        status = "\(libraries.count) libraries klaar om te scannen."
    }

    private func scanAll() {
        let input = libraries
        scanning = true
        projects = []
        selectedProjectIDs = []
        results = []
        status = "Libraries worden read-only gescand…"

        Task {
            let found = await Task.detached(priority: .userInitiated) {
                BundleScanner.scan(libraries: input)
            }.value

            await MainActor.run {
                projects = found.sorted {
                    if $0.libraryName != $1.libraryName {
                        return $0.libraryName.localizedCaseInsensitiveCompare($1.libraryName) == .orderedAscending
                    }
                    return $0.projectName.localizedCaseInsensitiveCompare($1.projectName) == .orderedAscending
                }
                selectedProjectIDs = Set(projects.map(\.id))
                scanning = false
                status = "\(projects.count) projecten gevonden. Vink nu versies uit die niet moeten meetellen."
            }
        }
    }

    private func selectLikelyLatest() {
        let groups = Dictionary(grouping: projects) {
            $0.libraryURL.path + "::" + $0.family
        }

        var chosen: Set<UUID> = []

        for group in groups.values {
            guard let best = group.max(by: {
                let a = ProjectVersion.score(for: $0.projectName)
                let b = ProjectVersion.score(for: $1.projectName)
                if a.0 != b.0 { return a.0 < b.0 }
                if a.1 != b.1 { return a.1 < b.1 }
                if a.2 != b.2 { return a.2 < b.2 }
                return a.3 < b.3
            }) else { continue }
            chosen.insert(best.id)
        }

        selectedProjectIDs = chosen
    }

    private func exportSelected() {
        let chosen = projects.filter { selectedProjectIDs.contains($0.id) }
        exporting = true
        results = []
        status = "Muziek wordt naar de rootschijf van iedere bron-library gekopieerd…"

        Task {
            do {
                let written = try await Task.detached(priority: .userInitiated) {
                    try OutputWriter.write(projects: chosen)
                }.value

                await MainActor.run {
                    results = written
                    exporting = false
                    status = written.map {
                        "\($0.volumeRoot.lastPathComponent.isEmpty ? $0.volumeRoot.path : $0.volumeRoot.lastPathComponent): \($0.copiedTracks) tracks uit \($0.selectedProjects) projecten"
                    }.joined(separator: " · ")

                    if let first = written.first {
                        NSWorkspace.shared.activateFileViewerSelecting([first.outputURL])
                    }
                }
            } catch {
                await MainActor.run {
                    exporting = false
                    errorMessage = """
                    Kon niet naar de root van de schijf schrijven.

                    \(error.localizedDescription)

                    Controleer of de schijf schrijfbaar is en of macOS de app toegang geeft tot verwisselbare volumes.
                    """
                    status = "Export mislukt."
                }
            }
        }
    }
}
