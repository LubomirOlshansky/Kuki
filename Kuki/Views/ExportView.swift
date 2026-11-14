import SwiftData
import SwiftUI
import UIKit

/// 書き出し — hand the log to a spreadsheet, or to Claude / ChatGPT.
struct ExportView: View {
    @Environment(Recorder.self) private var recorder
    @Environment(\.modelContext) private var context
    @State private var range: ExportRange = .week
    @State private var copied = false
    @State private var copying = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PageTitle(kanji: "書出", title: "Export")
                    .padding(.top, 12)

                Picker("Period", selection: $range) {
                    ForEach(ExportRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                ExportCount(range: range, filter: recorder.sensorFilter, refresh: recorder.lastRecordedAt)

                block(
                    title: "For Claude or ChatGPT",
                    text: "A Markdown file with a short brief, a summary per place and the data averaged so it fits in a chat. Attach the file, or copy it and paste it into the conversation."
                ) {
                    HStack(spacing: 12) {
                        ShareLink(item: file(.markdown), preview: SharePreview("Kūki air log (Markdown)")) {
                            pill("Share file", systemImage: "doc.text")
                        }
                        .help("Share the Markdown brief as a file")
                        Button(action: copyMarkdown) {
                            pill(copied ? "Copied" : "Copy text", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(copying)
                        .help("Copy the Markdown brief, to paste into a chat")
                    }
                }

                Hairline()

                block(
                    title: "Spreadsheet (CSV)",
                    text: "Every sample at full resolution: time, place, CO₂, temperature, humidity, PM2.5, and whether the sensor was still settling after a move. Opens in Numbers, Excel or Google Sheets."
                ) {
                    ShareLink(item: file(.csv), preview: SharePreview("Kūki air log (CSV)")) {
                        pill("Share CSV", systemImage: "tablecells")
                    }
                    .help("Share every sample as a CSV file")
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .paperBackground()
    }

    private func file(_ kind: ExportFile.Kind) -> ExportFile {
        ExportFile(kind: kind, since: range.start, limit: recorder.co2Limit, sensor: recorder.sensorName,
                   filter: recorder.sensorFilter, container: context.container)
    }

    /// Building the brief reads every row in the period — do it off the
    /// main actor, then hand the text to the pasteboard.
    private func copyMarkdown() {
        let (container, since, limit) = (context.container, range.start, recorder.co2Limit)
        let (sensor, filter) = (recorder.sensorName, recorder.sensorFilter)
        copying = true
        Task {
            let text = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let rows = try? Exporter.fetchRows(container: container, since: since, filter: filter) else { return nil }
                return Exporter.markdown(rows, limit: limit, sensor: sensor)
            }.value
            copying = false
            guard let text else { return }
            UIPasteboard.general.string = text
            copied = true
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func block<Content: View>(title: String, text: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Typeface.title).foregroundStyle(Ink.ink)
            Text(text).font(Typeface.body).foregroundStyle(Ink.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            content().padding(.top, 4)
        }
    }

    private func pill(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(Ink.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .overlay(Capsule().stroke(Ink.hairline, lineWidth: 1))
            .contentShape(Capsule())
            .quietHover(Capsule())
    }
}

private struct ExportCount: View {
    @Environment(\.modelContext) private var context
    let range: ExportRange
    let filter: SensorFilter
    let refresh: Date?

    @State private var counts: (samples: Int, places: Int)?

    private struct LoadKey: Hashable { let range: ExportRange; let filter: SensorFilter; let refresh: Date? }

    var body: some View {
        Group {
            if let counts {
                Text("\(counts.samples) samples · \(counts.places) place\(counts.places == 1 ? "" : "s")")
            } else {
                Text("Counting…")
            }
        }
        .kukiLabel()
        .task(id: LoadKey(range: range, filter: filter, refresh: refresh)) {
            let container = context.container
            let (range, filter) = (range, filter)
            while !Task.isCancelled {
                let since = range.start
                // A count, not the rows: 30 days at one a minute is 43 000 of them.
                let result = await Task.detached(priority: .utility) { () -> (Int, Int) in
                    let counts = (try? Exporter.counts(container: container, since: since, filter: filter)) ?? (samples: 0, places: 0)
                    return (counts.samples, counts.places)
                }.value
                if Task.isCancelled { break }
                counts = result
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}
