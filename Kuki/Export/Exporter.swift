import CoreTransferable
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Turns the log into files you can hand to a spreadsheet (CSV) or to an AI
/// assistant like Claude or ChatGPT (Markdown with context + a compact table).
enum ExportRange: String, CaseIterable, Identifiable, Sendable {
    case day, week, month, all
    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: String(localized: "24 h", comment: "Export: period option, the last 24 hours (segmented control, keep very short)")
        case .week: String(localized: "7 days", comment: "Export: period option, the last 7 days (segmented control, keep short)")
        case .month: String(localized: "30 days", comment: "Export: period option, the last 30 days (segmented control, keep short)")
        case .all: String(localized: "All", comment: "Export: period option, all recorded history (segmented control, keep short)")
        }
    }

    var start: Date {
        switch self {
        case .day: .now.addingTimeInterval(-24 * 3600)
        case .week: .now.addingTimeInterval(-7 * 24 * 3600)
        case .month: .now.addingTimeInterval(-30 * 24 * 3600)
        case .all: .distantPast
        }
    }
}

/// Plain copy of a reading, safe to pass around off the main actor.
struct Row: Sendable, Equatable {
    let time: Date
    /// The place's name to show: the live name when the place still exists
    /// (so a rename doesn't split history), otherwise the name it had.
    let place: String
    let placeID: UUID?
    let co2: Double?
    let temperature: Double?
    let humidity: Double?
    let pm25: Double?
    let settling: Bool
    let sensor: String
    /// The device that recorded it (iCloud sync); nil = this device, before
    /// sync stamped readings.
    let origin: String?

    /// What groups readings into one place: its id, or — for readings whose
    /// place was never known — the stored name.
    var placeKey: String { placeID.map { "id:\($0.uuidString)" } ?? "name:\(place)" }

    init(_ r: Reading, liveNames: [UUID: String] = [:]) {
        time = r.timestamp
        placeID = r.placeID
        place = r.placeID.flatMap { liveNames[$0] } ?? r.placeName
        co2 = r.co2; temperature = r.temperature; humidity = r.humidity; pm25 = r.pm25
        settling = r.settling
        sensor = r.sensorName
        origin = r.originDeviceID
    }

    init(time: Date, place: String, placeID: UUID? = nil, co2: Double?, temperature: Double?,
         humidity: Double?, pm25: Double?, settling: Bool, sensor: String = "", origin: String? = nil) {
        self.time = time; self.place = place; self.placeID = placeID
        self.co2 = co2; self.temperature = temperature; self.humidity = humidity; self.pm25 = pm25
        self.settling = settling
        self.sensor = sensor
        self.origin = origin
    }

    /// The same reading, shown under another place.
    func filed(under placeID: UUID?, name: String) -> Row {
        Row(time: time, place: name, placeID: placeID, co2: co2, temperature: temperature, humidity: humidity,
            pm25: pm25, settling: settling, sensor: sensor, origin: origin)
    }

    func value(_ metric: Metric) -> Double? {
        switch metric {
        case .co2: co2
        case .temperature: temperature
        case .humidity: humidity
        case .pm25: pm25
        }
    }
}

/// Per-place summary — the numbers that answer "which room is worst?".
struct PlaceStats: Identifiable, Sendable, Equatable {
    /// `Row.placeKey` — stable across renames.
    let key: String
    let place: String
    let from: Date
    let to: Date
    let samples: Int
    let hours: Double
    let avgCO2: Double?
    let peakCO2: Double?
    let shareOverLimit: Double?
    let avgTemp: Double?
    let avgHumidity: Double?
    let avgPM25: Double?
    var id: String { key }

    func average(_ metric: Metric) -> Double? {
        switch metric {
        case .co2: avgCO2
        case .temperature: avgTemp
        case .humidity: avgHumidity
        case .pm25: avgPM25
        }
    }

    static func compute(_ rows: [Row], limit: Double) -> [PlaceStats] {
        let settled = rows.filter { !$0.settling }
        let groups = Dictionary(grouping: settled, by: \.placeKey)
        return groups.map { key, rows in
            let sorted = rows.sorted { $0.time < $1.time }
            let co2 = sorted.compactMap(\.co2)
            // Hours actually observed: sum of gaps between consecutive
            // samples, ignoring gaps longer than 15 min (the app was closed).
            var seconds = 0.0
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                let gap = b.time.timeIntervalSince(a.time)
                if gap <= 900 { seconds += gap }
            }
            return PlaceStats(
                key: key,
                place: sorted.last?.place ?? "",
                from: sorted.first?.time ?? .now,
                to: sorted.last?.time ?? .now,
                samples: sorted.count,
                hours: seconds / 3600,
                avgCO2: co2.average,
                peakCO2: co2.max(),
                shareOverLimit: co2.isEmpty ? nil : Double(co2.filter { $0 >= limit }.count) / Double(co2.count),
                avgTemp: sorted.compactMap(\.temperature).average,
                avgHumidity: sorted.compactMap(\.humidity).average,
                avgPM25: sorted.compactMap(\.pm25).average
            )
        }
        .sorted { ($0.avgCO2 ?? 0, $1.place) > ($1.avgCO2 ?? 0, $0.place) }
    }
}

extension Array where Element == Double {
    var average: Double? { isEmpty ? nil : reduce(0, +) / Double(count) }
}

enum Exporter {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    /// Machine-readable numbers: `String(format:)` without a locale is POSIX
    /// ("19.6", never "19,6" or Arabic-Indic digits), whatever the app's language.
    private static func n(_ v: Double?, _ digits: Int = 0) -> String {
        guard let v else { return "" }
        return String(format: "%.\(digits)f", v)
    }

    // MARK: CSV — every sample, full resolution

    static func csv(_ rows: [Row]) -> String {
        var out = "timestamp,place,co2_ppm,temperature_c,humidity_pct,pm25_ugm3,settling\n"
        out.reserveCapacity(rows.count * 64)
        for r in rows {
            out += "\(iso.string(from: r.time)),\(csvField(r.place)),\(n(r.co2)),\(n(r.temperature, 1)),\(n(r.humidity)),\(n(r.pm25)),\(r.settling ? 1 : 0)\n"
        }
        return out
    }

    /// RFC 4180: quote a field containing a comma, a quote or a line break,
    /// and double any quote inside it.
    static func csvField(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// A Markdown table cell: a `|` would end the cell, a line break the row.
    static func markdownCell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|")
            .components(separatedBy: .newlines).joined(separator: " ")
    }

    // MARK: Markdown — made to be pasted into Claude / ChatGPT
    //
    // The prose (title, headings, the brief and the context notes) is in the
    // app's language: the user reads what they paste, and the assistant reads
    // any language. The data stays machine-readable in every language: the
    // summary table's column headers, the CSV block, POSIX numbers and units.

    /// `sensor` is a fallback; the brief names the sensors the rows actually came from.
    static func markdown(_ rows: [Row], limit: Double, sensor: String) -> String {
        let stats = PlaceStats.compute(rows, limit: limit)
        let bucket = bucketMinutes(for: rows)
        let compact = downsample(rows, minutes: bucket)
        let dateStyle = Date.FormatStyle(date: .abbreviated, time: .shortened)
        let sensors = orderedUnique(rows.map(\.sensor).filter { !$0.isEmpty })
        let sensorText = sensors.isEmpty ? sensor : sensors.joined(separator: ", ")
        let limitText = n(limit)
        let exported = Date.now.formatted(dateStyle)
        let zone = TimeZone.current.identifier
        let first = rows.first.map { $0.time.formatted(dateStyle) } ?? "—"
        let last = rows.last.map { $0.time.formatted(dateStyle) } ?? "—"
        let sampleCount = rows.count

        let title = String(localized: "Indoor air log — exported from Kūki",
                           comment: "Markdown export brief for an AI assistant: document title")
        let ask = String(localized: "I moved one air-quality sensor (\(sensorText)) between rooms of my home and logged it. Please analyse this data: compare the rooms, spot patterns by time of day, and tell me concretely when and where I should ventilate, and anything else worth changing.",
                         comment: "Markdown export brief for an AI assistant: the user's request, written in the first person. Placeholder is the sensor's name, e.g. ALPSTUGA.")
        let contextHeading = String(localized: "Context", comment: "Markdown export brief for an AI assistant: section heading")
        let exportedLine = String(localized: "Exported: \(exported) (time zone \(zone))",
                                  comment: "Markdown export brief for an AI assistant: bullet. Placeholders: the export date and time, then a time-zone identifier such as Europe/Berlin.")
        let periodLine = String(localized: "Period: \(first) → \(last)",
                                comment: "Markdown export brief for an AI assistant: bullet. Placeholders: first and last sample's date and time.")
        let samplesLine = String(localized: "Samples: \(sampleCount)",
                                 comment: "Markdown export brief for an AI assistant: bullet with the number of samples (a label, not a sentence)")
        let bucketLine = String(localized: "The table below is averaged into \(bucket)-minute buckets.",
                                comment: "Markdown export brief for an AI assistant: bullet. Placeholder is a number of minutes (1 to 240).")
        let unitsLine = String(localized: "Units: CO₂ in ppm, temperature in °C, relative humidity in %, PM2.5 in µg/m³.",
                               comment: "Markdown export brief for an AI assistant: bullet. Keep the units ppm, °C, %, µg/m³ and the names CO₂ and PM2.5.")
        let placeLine = String(localized: "Each \"place\" is where the sensor sat. The CO₂ cell needs ~10 minutes to adapt after a move; those samples are flagged `settling` and left out of the summary.",
                               comment: "Markdown export brief for an AI assistant: bullet. Keep `settling` in backticks unchanged: it is the CSV column name.")
        let gapsLine = String(localized: "Gaps in time mean the app was closed — no data, not clean air.",
                              comment: "Markdown export brief for an AI assistant: bullet")
        let referenceLine = String(localized: "Reference: outdoor CO₂ ≈ 420 ppm · under 800 good · 800–1000 acceptable · over 1000 ventilation advised (my alert limit is \(limitText) ppm) · over 1400 poor. Comfortable humidity 40–60 %. WHO PM2.5 24-hour guideline: 15 µg/m³.",
                                   comment: "Markdown export brief for an AI assistant: bullet with reference CO₂ levels. Placeholder is the user's CO₂ alert limit, e.g. 1000. WHO = World Health Organization (use its usual abbreviation in your language).")
        let summaryHeading = String(localized: "Summary by place",
                                    comment: "Markdown export brief for an AI assistant: section heading above a per-room table")
        let dataHeading = String(localized: "Data (\(bucket)-minute averages)",
                                 comment: "Markdown export brief for an AI assistant: section heading above the CSV data. Placeholder is a number of minutes (1 to 240).")

        // The table's column headers stay as they are in every language: they
        // label data, like the CSV columns below.
        var md = """
        # \(title)

        \(ask)

        ## \(contextHeading)
        - \(exportedLine)
        - \(periodLine)
        - \(samplesLine)
        - \(bucketLine)
        - \(unitsLine)
        - \(placeLine)
        - \(gapsLine)
        - \(referenceLine)

        ## \(summaryHeading)
        | Place | Hours | Avg CO₂ | Peak CO₂ | Time ≥ \(limitText) ppm | Avg °C | Avg %RH | Avg PM2.5 |
        |---|---:|---:|---:|---:|---:|---:|---:|

        """
        for s in stats {
            let share = s.shareOverLimit.map { "\(Int(($0 * 100).rounded())) %" } ?? ""
            md += "| \(markdownCell(s.place)) | \(n(s.hours, 1)) | \(n(s.avgCO2)) | \(n(s.peakCO2)) | \(share) | \(n(s.avgTemp, 1)) | \(n(s.avgHumidity)) | \(n(s.avgPM25)) |\n"
        }

        md += """

        ## \(dataHeading)
        ```csv
        \(csv(compact).trimmingCharacters(in: .newlines))
        ```

        """
        return md
    }

    private static func orderedUnique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    /// Keep the AI version under ~2,000 rows so it fits comfortably in a chat.
    private static func bucketMinutes(for rows: [Row]) -> Int {
        guard let first = rows.first?.time, let last = rows.last?.time else { return 1 }
        let minutes = last.timeIntervalSince(first) / 60
        for step in [1, 5, 10, 15, 30, 60, 120] where minutes / Double(step) <= 2000 {
            return step
        }
        return 240
    }

    static func downsample(_ rows: [Row], minutes: Int) -> [Row] {
        guard minutes > 1 else { return rows }
        let size = Double(minutes * 60)
        struct Key: Hashable { let slot: Int; let place: String }
        var groups: [Key: [Row]] = [:]
        var order: [Key] = []
        for r in rows {
            let key = Key(slot: Int(floor(r.time.timeIntervalSince1970 / size)), place: r.placeKey)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(r)
        }
        return order.compactMap { key in
            guard let g = groups[key] else { return nil }
            return Row(
                time: Date(timeIntervalSince1970: Double(key.slot) * size),
                place: g.last?.place ?? "",
                placeID: g.first?.placeID,
                co2: g.compactMap(\.co2).average.map { $0.rounded() },
                temperature: g.compactMap(\.temperature).average,
                humidity: g.compactMap(\.humidity).average,
                pm25: g.compactMap(\.pm25).average,
                settling: g.allSatisfy(\.settling),
                sensor: g.first?.sensor ?? ""
            )
        }
    }

    /// Readings since `start`, oldest first, for the sensors `filter` allows —
    /// demo and real data never mix. Each reading is shown under the place it
    /// belongs to *now* (`ReadingPlaces`): the live name, so a renamed place
    /// stays one place; merged places as the survivor; a reading recorded
    /// without a place under the place the sensor was known to be in. Safe
    /// to call off the main actor.
    ///
    /// - Parameter book: what sync knows about places — the stored ledger
    ///   unless a test passes its own.
    static func fetchRows(container: ModelContainer, since start: Date, filter: SensorFilter,
                          book: PlaceBook? = nil) throws -> [Row] {
        let context = ModelContext(container)
        // A little before the period too: a placeless reading at its very
        // start can still be placed by its neighbour.
        let from = start.addingTimeInterval(-ReadingPlaces.nearby)
        let demoName = DemoSensor.name
        let predicate: Predicate<Reading>
        if filter == .demoOnly {
            predicate = #Predicate<Reading> { $0.timestamp >= from && $0.sensorName == demoName }
        } else {
            predicate = #Predicate<Reading> { $0.timestamp >= from && $0.sensorName != demoName }
        }
        let descriptor = FetchDescriptor<Reading>(predicate: predicate, sortBy: [SortDescriptor(\.timestamp)])
        let rows = try context.fetch(descriptor).map { Row($0) }
        let live = try livePlaces(context)
        let resolved = ReadingPlaces.resolve(rows, liveNames: live.names, liveKanji: live.kanji, book: book ?? .stored())
        return resolved.filter { $0.time >= start }
    }

    /// How many readings — and from how many places — `fetchRows` would
    /// return, without loading the values: a count, and only the columns
    /// that decide the place.
    static func counts(container: ModelContainer, since start: Date, filter: SensorFilter,
                       book: PlaceBook? = nil) throws -> (samples: Int, places: Int) {
        let context = ModelContext(container)
        let from = start.addingTimeInterval(-ReadingPlaces.nearby)
        let demoName = DemoSensor.name
        let predicate: Predicate<Reading>
        if filter == .demoOnly {
            predicate = #Predicate<Reading> { $0.timestamp >= from && $0.sensorName == demoName }
        } else {
            predicate = #Predicate<Reading> { $0.timestamp >= from && $0.sensorName != demoName }
        }
        var descriptor = FetchDescriptor<Reading>(predicate: predicate, sortBy: [SortDescriptor(\.timestamp)])
        descriptor.propertiesToFetch = [\.timestamp, \.placeID, \.placeName, \.sensorName, \.originDeviceID]
        let rows = try context.fetch(descriptor).map { r in
            Row(time: r.timestamp, place: r.placeName, placeID: r.placeID, co2: nil, temperature: nil,
                humidity: nil, pm25: nil, settling: false, sensor: r.sensorName, origin: r.originDeviceID)
        }
        let live = try livePlaces(context)
        let resolved = ReadingPlaces.resolve(rows, liveNames: live.names, liveKanji: live.kanji, book: book ?? .stored())
            .filter { $0.time >= start }
        return (resolved.count, Set(resolved.map(\.placeKey)).count)
    }

    /// Live places' stored names and kanji, by id (`ReadingPlaces` shows
    /// each under its `displayName`).
    private static func livePlaces(_ context: ModelContext) throws -> (names: [UUID: String], kanji: [UUID: String]) {
        let places = try context.fetch(FetchDescriptor<Place>())
        return (Dictionary(places.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }),
                Dictionary(places.map { ($0.id, $0.kanji) }, uniquingKeysWith: { a, _ in a }))
    }

    static func fileName(_ ext: String) -> String {
        let stamp = Date.now.formatted(.iso8601.year().month().day())
        return "kuki-air-\(stamp).\(ext)"
    }
}

/// A file built lazily, only when the share sheet actually asks for it.
struct ExportFile: Transferable {
    enum Kind: Hashable, Sendable { case csv, markdown }
    let kind: Kind
    /// Readings from this moment on.
    let since: Date
    let limit: Double
    let sensor: String
    let filter: SensorFilter
    let container: ModelContainer
    /// The period's name for `export_performed` (share sheets only; the Mac
    /// save panel reports from its own completion). nil = not reported.
    var reportRange: String? = nil

    static let markdownType = UTType("net.daringfireball.markdown") ?? .plainText

    var contentType: UTType { kind == .csv ? .commaSeparatedText : Self.markdownType }
    var fileExtension: String { kind == .csv ? "csv" : "md" }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { file in
            try file.write()
        }
        .exportingCondition { $0.kind == .csv }

        FileRepresentation(exportedContentType: markdownType) { file in
            try file.write()
        }
        .exportingCondition { $0.kind == .markdown }
    }

    private func write() throws -> SentTransferredFile {
        let rows = try Exporter.fetchRows(container: container, since: since, filter: filter)
        let text: String
        let name: String
        switch kind {
        case .csv:
            text = Exporter.csv(rows)
            name = Exporter.fileName("csv")
        case .markdown:
            text = Exporter.markdown(rows, limit: limit, sensor: sensor)
            name = Exporter.fileName("md")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let range = reportRange {
            let kind = kind
            Task { @MainActor in UsageAnalytics.shared.exportPerformed(format: kind, action: "share_file", range: range) }
        }
        return SentTransferredFile(url)
    }
}
