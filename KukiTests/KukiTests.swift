import Foundation
import SwiftData
import Testing
@testable import Kuki

// MARK: - CO₂ bands & visual mapping

@Suite("CO₂ levels")
struct CO2LevelTests {
    @Test("Band boundaries follow common indoor guidance", arguments: [
        (420.0, CO2Level.clear), (799.9, .clear), (800, .fine), (999, .fine),
        (1000, .stale), (1399, .stale), (1400, .poor), (5000, .poor),
    ])
    func bands(ppm: Double, expected: CO2Level) {
        #expect(CO2Level(ppm: ppm) == expected)
    }

    @Test func ensoNeverClosesOrVanishes() {
        #expect(EnsoRing.fraction(for: 0) == 0.10)
        #expect(EnsoRing.fraction(for: 400) == 0.10)
        #expect(EnsoRing.fraction(for: 10_000) == 0.94)
        #expect(abs(EnsoRing.fraction(for: 1200) - 0.5) < 0.0001)
    }

    @Test func motesGrowWithCO2() {
        #expect(AirMotes.count(for: 2000) == 90)
        #expect(AirMotes.count(for: 9000) == 90)
        let samples = stride(from: 400.0, through: 2000, by: 100).map(AirMotes.count)
        #expect(samples == samples.sorted())
    }

    @Test func clearAirHasNoMotes() {
        #expect(AirMotes.count(for: 400) == 0)
        #expect(AirMotes.count(for: 799) == 0)
        #expect(AirMotes.count(for: 800) > 0)
    }

    @Test func motesKeepOffTheReading() {
        let zone = AirMotes.exclusion(digits: 3)
        #expect(AirMotes.exclusionFade(x: 0, y: 0, zone: zone) == 0, "never on the numbers")
        #expect(AirMotes.exclusionFade(x: 0.3, y: 0.2, zone: zone) == 0)
        #expect(AirMotes.exclusionFade(x: 0, y: 0.8, zone: zone) == 1, "free above and below")
        #expect(AirMotes.exclusionFade(x: 0.85, y: 0, zone: zone) == 1)
        let edge = AirMotes.exclusionFade(x: 0, y: zone.height + 0.06, zone: zone)
        #expect(edge > 0 && edge < 1, "softened at the edge")
        #expect(AirMotes.exclusion(digits: 4).width > zone.width, "a wider reading clears more room")
    }

    @Test func motesFadeOneAfterAnother() {
        #expect(AirMotes.alpha(index: 3, count: 6) == 1)
        #expect(AirMotes.alpha(index: 5, count: 5.5) == 0.5)
        #expect(AirMotes.alpha(index: 6, count: 5.5) == 0)
    }
}

// MARK: - Metrics & menu bar setting

@Suite("Metrics")
struct MetricTests {
    @Test func formatting() {
        #expect(Metric.co2.format(812.4) == "812")
        #expect(Metric.temperature.format(21.46) == "21.5")
        #expect(Metric.humidity.format(47.6) == "48")
        #expect(Metric.pm25.format(nil) == "—")
        #expect(Metric.temperature.compact(21.4) == "21.4°")
        #expect(Metric.humidity.compact(48) == "48%")
        #expect(Metric.co2.compact(nil) == "—")
    }

    @Test func menuBarSettingParsesInCanonicalOrder() {
        #expect(Recorder.parseMetrics("humidity,co2") == [.co2, .humidity])
        #expect(Recorder.parseMetrics("co2,bogus,pm25") == [.co2, .pm25])
        #expect(Recorder.parseMetrics("") == [])
        #expect(Recorder.parseMetrics(nil) == [])
    }

    @MainActor @Test func menuBarNeverEmpty() {
        let recorder = Recorder(defaults: isolatedDefaults())

        recorder.menuBarMetrics = [.co2]
        recorder.setMenuBar(.temperature, shown: true)
        #expect(recorder.menuBarMetrics == [.co2, .temperature])
        recorder.setMenuBar(.co2, shown: false)
        #expect(recorder.menuBarMetrics == [.temperature])
        recorder.setMenuBar(.temperature, shown: false)
        #expect(recorder.menuBarMetrics == [.co2], "removing the last one falls back to CO₂")
    }
}

// MARK: - Helpers

/// A fresh, empty settings suite — tests never touch `.standard`.
private func isolatedDefaults() -> UserDefaults {
    let name = "kuki-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private let base = Date(timeIntervalSince1970: 1_800_000_000)

private func row(_ minutes: Double, _ place: String, placeID: UUID? = nil, co2: Double? = 800, temp: Double? = 21,
                 settling: Bool = false) -> Row {
    Row(time: base.addingTimeInterval(minutes * 60), place: place, placeID: placeID, co2: co2, temperature: temp,
        humidity: 50, pm25: 5, settling: settling)
}

private func memoryContainer() throws -> ModelContainer {
    try ModelContainer(for: Place.self, Reading.self,
                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
}

private func snapshot(co2: Double? = 900, heard: [Metric: Date], reachable: Bool = true,
                      firstSeen: Date = base) -> SensorSnapshot {
    SensorSnapshot(co2: co2, temperature: 21, humidity: 50, pm25: 5,
                   heardAt: heard, isReachable: reachable, firstSeen: firstSeen)
}

private func heardAll(at date: Date) -> [Metric: Date] {
    Dictionary(uniqueKeysWithValues: Metric.allCases.map { ($0, date) })
}

// MARK: - Export

@Suite("Export")
struct ExportTests {
    @Test func csvHeaderAndRows() {
        let csv = Exporter.csv([row(0, "Bedroom", co2: 912.4, temp: 19.56, settling: true),
                                row(1, "Kid's room, upstairs", co2: nil)])
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines[0] == "timestamp,place,co2_ppm,temperature_c,humidity_pct,pm25_ugm3,settling")
        #expect(lines.count == 3)
        #expect(lines[1].contains(",Bedroom,912,19.6,50,5,1"))
        #expect(lines[2].contains(",\"Kid's room, upstairs\",,21.0,50,5,0"), "commas quoted, missing values empty")
    }

    @Test func csvQuotesFollowRFC4180() {
        #expect(Exporter.csvField("Hall") == "Hall")
        #expect(Exporter.csvField("The \"good\" room") == "\"The \"\"good\"\" room\"")
        #expect(Exporter.csvField("Up\nstairs") == "\"Up\nstairs\"")
        let csv = Exporter.csv([row(0, "Mum's \"study\", top\nfloor")])
        #expect(csv.contains(",\"Mum's \"\"study\"\", top\nfloor\",800,"))
    }

    @Test func markdownEscapesPipesInPlaceNames() {
        let md = Exporter.markdown([row(0, "Hall | stairs"), row(1, "Hall | stairs")], limit: 1000, sensor: "ALPSTUGA")
        #expect(md.contains("| Hall \\| stairs |"))
        #expect(Exporter.markdownCell("a|b\nc") == "a\\|b c")
    }

    @Test func markdownNamesTheSensorTheRowsCameFrom() {
        let rows = [Row(time: base, place: "Hall", co2: 700, temperature: nil, humidity: nil, pm25: nil,
                        settling: false, sensor: "ALPSTUGA")]
        let md = Exporter.markdown(rows, limit: 1000, sensor: "Sensor")
        #expect(md.contains("sensor (ALPSTUGA)"))
    }

    @Test func downsampleAveragesPerPlaceAndBucket() {
        let rows = [row(0, "A", co2: 600), row(1, "A", co2: 800), row(2, "B", co2: 1200), row(6, "A", co2: 1000)]
        let out = Exporter.downsample(rows, minutes: 5)
        let a = out.filter { $0.place == "A" }
        let b = out.filter { $0.place == "B" }
        #expect(b.count == 1 && b[0].co2 == 1200)
        #expect(a.count == 2)
        #expect(a.compactMap(\.co2).sorted() == [700, 1000])
    }

    @Test func downsampleByOneMinuteIsIdentity() {
        let rows = (0..<10).map { row(Double($0), "A") }
        #expect(Exporter.downsample(rows, minutes: 1).count == 10)
    }

    @Test func markdownBriefsTheAssistant() {
        // Three days at 2-minute spacing → too many rows for a chat, so 5-minute buckets.
        let rows = stride(from: 0.0, to: 3 * 24 * 60, by: 2).map { row($0, $0 < 2000 ? "Bedroom" : "Study") }
        let md = Exporter.markdown(rows, limit: 1000, sensor: "ALPSTUGA")
        #expect(md.hasPrefix("# Indoor air log"))
        #expect(md.contains("5-minute"))
        #expect(md.contains("| Bedroom |"))
        #expect(md.contains("| Study |"))
        #expect(md.contains("```csv"))
        let dataLines = md.components(separatedBy: "```csv\n")[1].split(separator: "\n").count
        #expect(dataLines <= 2001, "fits comfortably in a chat")
    }
}

@Suite("Per-place statistics")
struct PlaceStatsTests {
    @Test func settlingSamplesAreLeftOut() {
        let rows = [row(0, "Bedroom", co2: 2000, settling: true),
                    row(1, "Bedroom", co2: 900), row(2, "Bedroom", co2: 1100)]
        let stats = PlaceStats.compute(rows, limit: 1000)
        #expect(stats.count == 1)
        #expect(stats[0].samples == 2)
        #expect(stats[0].avgCO2 == 1000)
        #expect(stats[0].peakCO2 == 1100)
        #expect(stats[0].shareOverLimit == 0.5)
    }

    @Test func gapsLongerThan15MinutesDoNotCountAsObserved() {
        let rows = [row(0, "Study"), row(10, "Study"), row(130, "Study"), row(140, "Study")]
        let stats = PlaceStats.compute(rows, limit: 1000)
        #expect(abs(stats[0].hours - 20.0 / 60) < 0.0001)
    }

    @Test func renamedPlaceStaysOnePlace() {
        let id = UUID()
        let rows = [row(0, "Bedroom", placeID: id, co2: 900), row(1, "Bedroom", placeID: id, co2: 1100),
                    row(2, "Sleeping room", placeID: id, co2: 1000), row(3, "Study", co2: 600)]
        let stats = PlaceStats.compute(rows, limit: 1000)
        #expect(stats.count == 2)
        let bedroom = stats.first { $0.key == rows[0].placeKey }
        #expect(bedroom?.samples == 3)
        #expect(bedroom?.place == "Sleeping room", "the latest name is shown")
        // Downsampling and visits follow the place, not its name, too.
        #expect(Exporter.downsample(Array(rows.prefix(3)), minutes: 5).count == 1)
        #expect(Set(HistoryBody.segments(Array(rows.prefix(3)), gap: 600).map(\.segment)) == [0])
    }

    @Test func seriesNamesStayUnique() {
        let rows = [row(0, "Bedroom", placeID: UUID()), row(1, "Bedroom", placeID: UUID())]
        #expect(HistoryModel.orderedSeries(rows).map(\.name) == ["Bedroom", "Bedroom (2)"])
    }

    @Test func worstPlaceFirst() {
        let rows = [row(0, "Kitchen", co2: 700), row(1, "Bedroom", co2: 1500), row(2, "Study", co2: 1000)]
        #expect(PlaceStats.compute(rows, limit: 1000).map(\.place) == ["Bedroom", "Study", "Kitchen"])
    }
}

// MARK: - Storage

@Suite("Storage")
struct StorageTests {
    @Test func fetchRowsFiltersAndSorts() throws {
        let container = try memoryContainer()
        let context = ModelContext(container)
        let now = Date.now
        for minutes in [30.0, -5, 10, 90] {
            context.insert(Reading(timestamp: now.addingTimeInterval(-minutes * 60), co2: 700, temperature: nil,
                                   humidity: nil, pm25: nil, placeID: nil, placeName: "Hall",
                                   settling: false, sensorName: "t"))
        }
        try context.save()
        let rows = try Exporter.fetchRows(container: container, since: now.addingTimeInterval(-60 * 60),
                                          filter: .excludingDemo)
        #expect(rows.count == 3)
        #expect(rows.map(\.time) == rows.map(\.time).sorted())
    }

    @Test func demoAndRealReadingsNeverMix() throws {
        let container = try memoryContainer()
        let context = ModelContext(container)
        let now = Date.now
        for (i, sensor) in [DemoSensor.name, "ALPSTUGA", DemoSensor.name, "ALPSTUGA", "ALPSTUGA"].enumerated() {
            context.insert(Reading(timestamp: now.addingTimeInterval(-Double(i) * 60), co2: 700, temperature: nil,
                                   humidity: nil, pm25: nil, placeID: nil, placeName: "Hall",
                                   settling: false, sensorName: sensor))
        }
        try context.save()
        let since = now.addingTimeInterval(-3600)
        let real = try Exporter.fetchRows(container: container, since: since, filter: .excludingDemo)
        let demo = try Exporter.fetchRows(container: container, since: since, filter: .demoOnly)
        #expect(real.count == 3 && real.allSatisfy { $0.sensor == "ALPSTUGA" })
        #expect(demo.count == 2 && demo.allSatisfy { $0.sensor == DemoSensor.name })
        #expect(SensorFilter(useDemo: true) == .demoOnly)
        #expect(SensorFilter(useDemo: false) == .excludingDemo)
    }

    @Test func fetchRowsShowsTheLiveNameOfARenamedPlace() throws {
        let container = try memoryContainer()
        let context = ModelContext(container)
        let place = Place(name: "Sleeping room")
        context.insert(place)
        let deletedID = UUID()
        let now = Date.now
        context.insert(Reading(timestamp: now.addingTimeInterval(-120), co2: 900, temperature: nil, humidity: nil,
                               pm25: nil, placeID: place.id, placeName: "Bedroom", settling: false, sensorName: "s"))
        context.insert(Reading(timestamp: now.addingTimeInterval(-60), co2: 950, temperature: nil, humidity: nil,
                               pm25: nil, placeID: place.id, placeName: "Sleeping room", settling: false, sensorName: "s"))
        context.insert(Reading(timestamp: now, co2: 600, temperature: nil, humidity: nil,
                               pm25: nil, placeID: deletedID, placeName: "Attic", settling: false, sensorName: "s"))
        try context.save()
        let rows = try Exporter.fetchRows(container: container, since: now.addingTimeInterval(-3600), filter: .excludingDemo)
        #expect(rows.map(\.place) == ["Sleeping room", "Sleeping room", "Attic"], "deleted places keep their stored name")
        let stats = PlaceStats.compute(rows, limit: 1000)
        #expect(stats.map(\.place).sorted() == ["Attic", "Sleeping room"])
        #expect(stats.first { $0.place == "Sleeping room" }?.samples == 2)
    }

    @MainActor @Test func demoHistoryIsPlausible() throws {
        let container = try memoryContainer()
        let context = container.mainContext
        let places = Place.defaults.enumerated().map { Place(name: $1.0, kanji: $1.1, sortIndex: $0) }
        places.forEach(context.insert)
        DemoSensor.seedHistory(into: context, places: places)
        let readings = try context.fetch(FetchDescriptor<Reading>())
        #expect(readings.count > 2000)
        #expect(readings.allSatisfy { ($0.co2 ?? 0) >= 300 && ($0.co2 ?? 0) <= 2500 })
        #expect(Set(readings.map(\.placeName)).count >= 3)
        #expect(readings.allSatisfy { $0.timestamp <= .now })
    }

    @Test func demoSensorStaysInRange() {
        var sensor = DemoSensor()
        for _ in 0..<5000 { sensor.step() }
        let s = sensor.snapshot
        #expect((430...1900).contains(s.co2 ?? 0))
        #expect((18...26).contains(s.temperature ?? 0))
        #expect((30...70).contains(s.humidity ?? 0))
        #expect((1...40).contains(s.pm25 ?? 0))
    }
}

@Suite("History chart")
struct ChartSegmentTests {
    @Test func aPlacesLineBreaksOnlyOnItsOwnGaps() {
        let rows = [row(0, "Kitchen"), row(1, "Kitchen"),      // Kitchen, stretch 0
                    row(2, "Bedroom"),                         // Bedroom's only reading
                    row(3, "Kitchen"),                         // Kitchen 2 min later: still stretch 0
                    row(200, "Kitchen")]                       // app was closed → Kitchen, stretch 1
        let points = HistoryBody.segments(rows, gap: 15 * 60)
        #expect(points.map(\.segment) == [0, 0, 0, 0, 1])
        #expect(points.map(\.isSingle) == [false, false, true, false, true], "lone points are drawn as dots")
        #expect(Set(points.map(\.series)).count == 3, "one line per (place, stretch)")
    }

    @Test("Gap is never shorter than three recording intervals", arguments: [1, 5, 10])
    func gapFollowsTheRecordingInterval(interval: Int) {
        // The 3 h chart uses 1-minute buckets; at 5 or 10-minute logging the
        // old 3-minute gap broke every sample into its own invisible "line".
        let gap = HistoryBody.segmentGap(bucketMinutes: ChartRange.hours3.bucketMinutes, intervalMinutes: interval)
        #expect(gap == Double(max(1, interval)) * 60 * 3)
        let rows = stride(from: 0.0, to: 180, by: Double(interval)).map { row($0, "Study") }
        let points = HistoryBody.segments(rows, gap: gap)
        #expect(Set(points.map(\.segment)) == [0])
        #expect(points.allSatisfy { !$0.isSingle })
    }

    @Test func spacingLargerThanTheGapGivesDots() {
        let rows = stride(from: 0.0, to: 60, by: 10).map { row($0, "Study") }
        let points = HistoryBody.segments(rows, gap: 3 * 60)
        #expect(points.count == 6)
        #expect(Set(points.map(\.segment)).count == 6)
        #expect(points.allSatisfy { $0.isSingle })
    }

    @Test func rowsWithoutTheMetricAreSkipped() {
        let rows = [row(0, "Hall", co2: nil), row(1, "Hall"), row(2, "Hall")]
        #expect(HistoryBody.segments(rows, gap: 600, metric: .co2).count == 2)
        #expect(HistoryBody.segments(rows, gap: 600, metric: .temperature).count == 3)
    }

    @Test func summarySentence() {
        let rows = [row(0, "Bedroom", co2: 1200), row(1, "Bedroom", co2: 1300), row(2, "Study", co2: 700)]
        let stats = PlaceStats.compute(rows, limit: 1000)
        #expect(HistoryBody.summary(stats, metric: .co2, limit: 1000) == "Bedroom was over the limit 100% of the time.")
    }
}

// MARK: - Sensor freshness

@Suite("Freshness")
struct FreshnessTests {
    @Test func freshValuesAreRecordable() {
        let s = snapshot(heard: heardAll(at: base))
        #expect(!s.isStale(now: base.addingTimeInterval(9 * 60)))
        #expect(s.recordable(now: base.addingTimeInterval(9 * 60)) == s)
    }

    @Test func valuesOlderThanTenMinutesAreNotRecorded() {
        let s = snapshot(heard: heardAll(at: base))
        let later = base.addingTimeInterval(11 * 60)
        #expect(s.isStale(now: later))
        #expect(s.recordable(now: later) == nil)
        #expect(s.freshValue(.co2, now: later) == nil, "a stale value never rings the chime")
    }

    @Test func onlyTheStaleMetricIsDropped() {
        let s = snapshot(heard: [.co2: base.addingTimeInterval(10 * 60), .temperature: base])
        let out = s.recordable(now: base.addingTimeInterval(12 * 60))
        #expect(out?.co2 == 900)
        #expect(out?.temperature == nil)
        #expect(out?.humidity == nil, "never heard at all")
    }

    @Test func unreachableSensorIsStaleAtOnce() {
        let s = snapshot(heard: heardAll(at: base), reachable: false)
        #expect(s.isStale(now: base))
        #expect(s.recordable(now: base) == nil)
    }

    @Test func cachedValuesAreShownBrieflyButNeverLogged() {
        let s = snapshot(heard: [:], firstSeen: base)
        #expect(!s.isStale(now: base.addingTimeInterval(30)), "grace while HomeKit answers")
        #expect(s.isStale(now: base.addingTimeInterval(90)))
        #expect(s.recordable(now: base.addingTimeInterval(30)) == nil)
        #expect(s.lastHeard == nil)
    }

    @MainActor @Test func recorderSkipsStaleSnapshots() throws {
        let container = try memoryContainer()
        let recorder = Recorder(defaults: isolatedDefaults(), clock: { base })
        recorder.configure(container: container)
        let stale = snapshot(heard: heardAll(at: base.addingTimeInterval(-11 * 60)))
        #expect(!recorder.record(stale, at: base))
        #expect(recorder.lastRecordedAt == nil)
        let count = try container.mainContext.fetchCount(FetchDescriptor<Reading>())
        #expect(count == 0)

        let fresh = snapshot(heard: heardAll(at: base.addingTimeInterval(-60)))
        #expect(recorder.record(fresh, at: base))
        let readings = try container.mainContext.fetch(FetchDescriptor<Reading>())
        #expect(readings.count == 1)
        #expect(readings.first?.co2 == 900)
        #expect(readings.first?.placeName == "Living room", "seeded places, first one current")
        #expect(recorder.lastRecordedAt == base)
    }
}

// MARK: - Recording interval

@Suite("Recording interval")
struct RecordScheduleTests {
    @Test("Due once a full interval has passed", arguments: [1, 5, 10])
    func gating(minutes: Int) {
        let interval = Double(minutes) * 60
        #expect(RecordSchedule.isDue(lastRecordedAt: nil, intervalMinutes: minutes, now: base))
        #expect(!RecordSchedule.isDue(lastRecordedAt: base, intervalMinutes: minutes, now: base.addingTimeInterval(interval - 15)))
        #expect(RecordSchedule.isDue(lastRecordedAt: base, intervalMinutes: minutes, now: base.addingTimeInterval(interval)))
        #expect(RecordSchedule.isDue(lastRecordedAt: base, intervalMinutes: minutes, now: base.addingTimeInterval(interval - 1)),
                "a tick a moment early still counts")
    }

    @Test func zeroIntervalMeansEveryMinute() {
        #expect(!RecordSchedule.isDue(lastRecordedAt: base, intervalMinutes: 0, now: base.addingTimeInterval(30)))
        #expect(RecordSchedule.isDue(lastRecordedAt: base, intervalMinutes: 0, now: base.addingTimeInterval(60)))
    }
}

// MARK: - Alert

/// `#expect` can't call a mutating method; this does it outside the macro.
private func ring(_ gate: inout AlertGate, co2: Double?, limit: Double, settling: Bool, now: Date) -> Bool {
    gate.evaluate(co2: co2, limit: limit, settling: settling, now: now)
}

@Suite("Alert gate")
struct AlertGateTests {
    private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    @Test func ringsOnceAtTheLimit() {
        var gate = AlertGate()
        #expect(!ring(&gate, co2: 990, limit: 1000, settling: false, now: at(0)))
        #expect(ring(&gate, co2: 1000, limit: 1000, settling: false, now: at(1)))
        #expect(!ring(&gate, co2: 1200, limit: 1000, settling: false, now: at(2)))
        #expect(!ring(&gate, co2: 1400, limit: 1000, settling: false, now: at(60)), "still not recovered")
        #expect(gate.lastAlertAt == at(1))
    }

    @Test func reArmsOnlyBelowLimitMinus100() {
        var gate = AlertGate()
        #expect(ring(&gate, co2: 1050, limit: 1000, settling: false, now: at(0)))
        #expect(!ring(&gate, co2: 950, limit: 1000, settling: false, now: at(30)))   // hovering
        #expect(!ring(&gate, co2: 1050, limit: 1000, settling: false, now: at(31)))
        #expect(!ring(&gate, co2: 899, limit: 1000, settling: false, now: at(40)))   // clearly better
        #expect(gate.armed)
        #expect(ring(&gate, co2: 1050, limit: 1000, settling: false, now: at(41)))
    }

    @Test func twentyMinuteCooldown() {
        var gate = AlertGate()
        #expect(ring(&gate, co2: 1100, limit: 1000, settling: false, now: at(0)))
        #expect(!ring(&gate, co2: 700, limit: 1000, settling: false, now: at(2)))
        #expect(!ring(&gate, co2: 1100, limit: 1000, settling: false, now: at(10)), "armed, but cooling down")
        #expect(ring(&gate, co2: 1100, limit: 1000, settling: false, now: at(21)))
    }

    @Test func quietWhileSettling() {
        var gate = AlertGate()
        #expect(!ring(&gate, co2: 1500, limit: 1000, settling: true, now: at(0)))
        #expect(gate.armed, "settling doesn't use up the alert")
        #expect(ring(&gate, co2: 1500, limit: 1000, settling: false, now: at(10)))
    }

    @Test func movingReArms() {
        var gate = AlertGate()
        #expect(ring(&gate, co2: 1200, limit: 1000, settling: false, now: at(0)))
        #expect(!ring(&gate, co2: 1200, limit: 1000, settling: false, now: at(30)))
        gate.rearm()
        #expect(ring(&gate, co2: 1200, limit: 1000, settling: false, now: at(31)))
    }

    @Test func unknownOrStaleCO2NeverRings() {
        var gate = AlertGate()
        #expect(!ring(&gate, co2: nil, limit: 1000, settling: false, now: at(0)))
        #expect(gate.armed)
    }
}


@Suite("Reach judge — no false 'out of reach' on return")
struct ReachJudgeTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func freshIsLive() {
        var judge = ReachJudge()
        #expect(judge.evaluate(rawStale: false, now: t0) == .live)
    }

    @Test func returningFromBackgroundCatchesUpFirst() {
        var judge = ReachJudge()
        judge.appResumed(at: t0)
        // Values aged while frozen: raw-stale at once, but only catching up.
        #expect(judge.evaluate(rawStale: true, now: t0) == .catchingUp)
        #expect(judge.evaluate(rawStale: true, now: t0.addingTimeInterval(10)) == .catchingUp)
        // Apple Home answered: live again, no "out of reach" shown at all.
        #expect(judge.evaluate(rawStale: false, now: t0.addingTimeInterval(12)) == .live)
    }

    @Test func silentPastGraceIsOutOfReach() {
        var judge = ReachJudge()
        judge.appResumed(at: t0)
        _ = judge.evaluate(rawStale: true, now: t0)
        #expect(judge.evaluate(rawStale: true, now: t0.addingTimeInterval(ReachJudge.grace + 1)) == .outOfReach)
    }

    @Test func aBlipWhileLiveIsForgiven() {
        var judge = ReachJudge()
        _ = judge.evaluate(rawStale: false, now: t0)
        #expect(judge.evaluate(rawStale: true, now: t0.addingTimeInterval(100)) == .catchingUp)
        #expect(judge.evaluate(rawStale: false, now: t0.addingTimeInterval(105)) == .live)
        // A new stale spell starts its own grace.
        #expect(judge.evaluate(rawStale: true, now: t0.addingTimeInterval(200)) == .catchingUp)
    }

    @Test func resumeRestartsTheGraceForAnOldOutage() {
        var judge = ReachJudge()
        _ = judge.evaluate(rawStale: true, now: t0)
        #expect(judge.evaluate(rawStale: true, now: t0.addingTimeInterval(60)) == .outOfReach)
        judge.appResumed(at: t0.addingTimeInterval(3600))
        #expect(judge.evaluate(rawStale: true, now: t0.addingTimeInterval(3601)) == .catchingUp)
    }
}

@Suite("Widget snapshot & sync")
struct WidgetSnapshotTests {
    @Test func roundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "kuki-test-\(UUID()).json")
        var s = WidgetSnapshot.placeholder
        s.measuredAt = Date(timeIntervalSince1970: 1_800_000_000)
        try s.save(to: url)
        #expect(WidgetSnapshot.load(from: url) == s)
    }

    @Test func staleAfterThirtyMinutes() {
        var s = WidgetSnapshot.placeholder
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        s.measuredAt = t
        #expect(!s.isStale(at: t.addingTimeInterval(29 * 60)))
        #expect(s.isStale(at: t.addingTimeInterval(31 * 60)))
    }

    @Test func thinKeepsShapeAndLength() {
        let values = (0..<180).map(Double.init)
        let thin = WidgetSnapshot.thin(values, to: 36)
        #expect(thin.count == 36)
        #expect(thin == thin.sorted())
        #expect(WidgetSnapshot.thin([1, 2, 3], to: 36) == [1, 2, 3])
    }

    @Test func newerSnapshotWins() {
        var a = WidgetSnapshot.placeholder, b = WidgetSnapshot.placeholder
        a.measuredAt = Date(timeIntervalSince1970: 100)
        b.measuredAt = Date(timeIntervalSince1970: 200)
        #expect(CloudSync.newer(a, b) == b)
        #expect(CloudSync.newer(nil, a) == a)
        #expect(CloudSync.newer(nil, nil) == nil)
    }

    @MainActor @Test func cloudAlertFollowsTheSameGate() throws {
        let defaults = try #require(UserDefaults(suiteName: "kuki-cloud-alert-\(UUID())"))
        defaults.set(true, forKey: "notifyOn")
        defaults.set(1000.0, forKey: "co2Limit")
        var s = WidgetSnapshot.placeholder
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        s.co2 = 1200; s.measuredAt = t
        #expect(CloudWake.alertDue(s, now: t, defaults: defaults) == 1200)
        #expect(AlertGate.load(from: defaults).lastAlertAt == t, "rang once")
        s.measuredAt = t.addingTimeInterval(60)
        #expect(CloudWake.alertDue(s, now: t.addingTimeInterval(60), defaults: defaults) == nil)
        #expect(AlertGate.load(from: defaults).lastAlertAt == t, "stays quiet while still stuffy")
    }

    @MainActor @Test func aCloudAlertIsNotRepeatedWhenTheAppOpens() throws {
        let name = "kuki-shared-alert-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        defaults.set(true, forKey: "notifyOn")
        defaults.set(1000.0, forKey: "co2Limit")
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        var s = WidgetSnapshot.placeholder
        s.co2 = 1250; s.measuredAt = t
        #expect(CloudWake.alertDue(s, now: t, defaults: defaults) == 1250, "the iCloud wake-up announces the spell")

        // The user opens the app a minute later — a fresh launch, still stuffy.
        var now = t.addingTimeInterval(60)
        let recorder = Recorder(defaults: defaults, clock: { now })
        #expect(recorder.lastAlertAt == t)
        #expect(!recorder.alertDue(co2: 1300, now: now), "the same spell doesn't ring again in the app")
        now = t.addingTimeInterval(45 * 60)
        #expect(!recorder.alertDue(co2: 1300, now: now), "nor after the cooldown, while it never cleared")

        // The air recovers below limit − 100, then gets stuffy again: a new spell.
        #expect(!recorder.alertDue(co2: 850, now: now))
        #expect(recorder.alertDue(co2: 1100, now: now.addingTimeInterval(60)))
        // …which the cloud path now knows too.
        s.co2 = 1150; s.measuredAt = now.addingTimeInterval(120)
        #expect(CloudWake.alertDue(s, now: now.addingTimeInterval(120), defaults: defaults) == nil)
    }

    @MainActor @Test func theOldCloudGateIsStillHonoured() throws {
        let name = "kuki-legacy-alert-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        var gate = AlertGate()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        _ = gate.evaluate(co2: 1200, limit: 1000, settling: false, now: t)
        defaults.set(try JSONEncoder().encode(gate), forKey: AlertGate.legacyCloudKey)
        #expect(AlertGate.load(from: defaults) == gate, "a gate saved by the previous build carries over")
    }
}


@Suite("Recent trace scale")
struct TraceScaleTests {
    @Test func calmAirZoomsToTheDataAndHidesTheLimit() {
        let scale = TraceScale(values: [418, 420, 422, 423], limit: 1000)
        #expect(!scale.showsLimit)
        #expect(scale.domain.lowerBound > 380 && scale.domain.upperBound < 450)
    }

    @Test func nearTheLimitShowsIt() {
        let scale = TraceScale(values: [700, 850, 920], limit: 1000)
        #expect(scale.showsLimit)
        #expect(scale.domain.upperBound > 1000)
    }
}


// MARK: - Brush ensō

@Suite("Ensō brush")
struct EnsoBrushTests {
    @Test func pressAtTheStartTaperAtTheTail() {
        let w = 9.0, length = 300.0
        #expect(EnsoGeometry.width(at: 0, length: length, lineWidth: w) > w * 1.15, "the brush lands heavy")
        #expect(EnsoGeometry.width(at: length, length: length, lineWidth: w) < w * 0.3, "and lifts thin")
        let body = EnsoGeometry.width(at: length / 2, length: length, lineWidth: w)
        #expect(body > w * 0.9 && body < w * 1.1)
    }

    @Test func tinyStrokesStayPositive() {
        // The 18 pt Dynamic Island mark: a short arc must still be a mark.
        for d in stride(from: 0.0, through: 3.4, by: 0.2) {
            #expect(EnsoGeometry.width(at: d, length: 3.4, lineWidth: 2.5) > 0)
        }
        #expect(EnsoGeometry.width(at: 1, length: 0, lineWidth: 2.5) == 0)
    }

    @Test func outlineStaysInItsFrame() {
        for size in [18.0, 44, 70, 118, 256] {
            let lw = max(2.5, size / 28)
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            let bounds = EnsoBrush(reach: 0.94, lineWidth: lw).path(in: rect).boundingRect
            // Like a stroked circle, at most about half the line width spills out.
            #expect(rect.insetBy(dx: -lw * 0.7, dy: -lw * 0.7).contains(bounds))
            #expect(EnsoBrush(reach: 0, lineWidth: lw).path(in: rect).isEmpty)
        }
    }

    @Test func kasureOnlyOnLongEnoughStrokes() {
        let rect = CGRect(x: 0, y: 0, width: 256, height: 256)
        #expect(!EnsoKasure(reach: 0.5, lineWidth: 9).path(in: rect).isEmpty)
        #expect(EnsoKasure(reach: 0.005, lineWidth: 9).path(in: rect).isEmpty)
    }
}

// MARK: - Now screen

@Suite("Settling")
struct SettleProgressTests {
    @Test func inkDriesAsTheSensorSettles() {
        #expect(SettleProgress.wetness(changedAt: base, minutes: 10, now: base) == 1)
        #expect(abs(SettleProgress.wetness(changedAt: base, minutes: 10, now: base.addingTimeInterval(300)) - 0.5) < 0.001)
        #expect(SettleProgress.wetness(changedAt: base, minutes: 10, now: base.addingTimeInterval(900)) == 0)
        #expect(SettleProgress.wetness(changedAt: base, minutes: 0, now: base) == 0, "settling off: always dry")
    }

    @Test func minutesLeftRoundUp() {
        #expect(SettleProgress.minutesLeft(changedAt: base, minutes: 10, now: base.addingTimeInterval(30)) == 10)
        #expect(SettleProgress.minutesLeft(changedAt: base, minutes: 10, now: base.addingTimeInterval(541)) == 1)
        #expect(SettleProgress.minutesLeft(changedAt: base, minutes: 10, now: base.addingTimeInterval(600)) == 0)
        #expect(SettleProgress.minutesLeft(changedAt: .distantPast, minutes: 10, now: base) == 0)
    }
}

// MARK: - History chart (selection, identity, headline)

@Suite("History chart — identity and readout")
struct HistoryChartTests {
    @Test func pointIdsSurviveTheMinutesReload() {
        let first = (0..<10).map { row(Double($0), $0 < 5 ? "Kitchen" : "Study") }
        // A minute later: the oldest reading has left the window, a new one arrived.
        let later = Array(first.dropFirst()) + [row(10, "Study")]
        let a = HistoryBody.segments(first, gap: 15 * 60)
        let b = HistoryBody.segments(later, gap: 15 * 60)
        let idsA = Dictionary(uniqueKeysWithValues: a.map { ($0.id, $0.time) })
        for p in b where idsA[p.id] != nil {
            #expect(idsA[p.id] == p.time, "the same id means the same reading")
        }
        #expect(Set(a.map(\.id)).intersection(b.map(\.id)).count == 9)
        #expect(Set(b.map(\.id)).count == b.count, "ids are unique")
    }

    @Test func nearestPointToAMoment() {
        let points = HistoryBody.segments((0..<6).map { row(Double($0) * 10, "Hall") }, gap: 3600)
        #expect(HistoryModel.nearest(in: points, to: base.addingTimeInterval(14 * 60))?.time == base.addingTimeInterval(10 * 60))
        #expect(HistoryModel.nearest(in: points, to: base.addingTimeInterval(16 * 60))?.time == base.addingTimeInterval(20 * 60))
        #expect(HistoryModel.nearest(in: points, to: base.addingTimeInterval(-600))?.time == base)
        #expect(HistoryModel.nearest(in: points, to: base.addingTimeInterval(9999 * 60))?.time == base.addingTimeInterval(50 * 60))
        #expect(HistoryModel.nearest(in: [], to: base) == nil)
    }

    @Test func headlineReadsLikeASentence() {
        let rows = [row(0, "Bedroom", co2: 1200), row(1, "Bedroom", co2: 1300), row(2, "Study", co2: 700)]
        let stats = PlaceStats.compute(rows, limit: 1000)
        #expect(HistoryBody.headline(stats, metric: .co2, limit: 1000) == "Bedroom was over the limit 100% of the time.")
        let calm = PlaceStats.compute([row(0, "Study", co2: 650), row(1, "Study", co2: 700)], limit: 1000)
        #expect(HistoryBody.headline(calm, metric: .co2, limit: 1000) == "Every place stayed under 1000 ppm. Study averaged 675.")
        let warm = PlaceStats.compute([row(0, "Kitchen", temp: 24), row(1, "Study", temp: 20)], limit: 1000)
        #expect(HistoryBody.headline(warm, metric: .temperature, limit: 1000) == "Kitchen was the warmest, 24.0 °C on average.")
    }

    @Test func placeEnsoUsesTheSameScaleAsTheBigOne() {
        #expect(HistoryBody.ensoFraction(metric: .co2, average: 1200, scaleMax: 1300) == EnsoRing.fraction(for: 1200))
        #expect(abs(HistoryBody.ensoFraction(metric: .temperature, average: 20, scaleMax: 20) - 0.94) < 0.0001)
        #expect(HistoryBody.ensoFraction(metric: .humidity, average: nil, scaleMax: 50) == 0.06)
    }
}

// MARK: - Station mode

@Suite("Station mode")
struct StationTests {
    @Test func everyLineIsLegibleOnBlack() {
        for contrast in [false, true] {
            let style = StationStyle(increasedContrast: contrast)
            for opacity in [style.numeral, style.secondary, style.tertiary] {
                #expect(StationStyle.contrastOnBlack(opacity: opacity) >= 4.5)
            }
        }
        #expect(StationStyle(increasedContrast: true).secondary > StationStyle().secondary)
    }

    @Test func driftStaysSmallAndMoves() {
        let offsets = (0..<120).map(StationDrift.offset(minute:))
        #expect(offsets.allSatisfy { abs($0.width) <= StationDrift.reach && abs($0.height) <= StationDrift.reach })
        #expect(Set(offsets.map { "\(Int($0.width)),\(Int($0.height))" }).count > 10, "it really wanders")
        #expect(StationDrift.minute(of: base) == StationDrift.minute(of: base.addingTimeInterval(59)) ||
                StationDrift.minute(of: base) + 1 == StationDrift.minute(of: base.addingTimeInterval(59)))
    }

    @Test func stationKeepsTheDisplayAwake() {
        #expect(Recorder.stationActivityOptions.contains(.idleDisplaySleepDisabled))
        #expect(Recorder.stationActivityOptions.contains(.idleSystemSleepDisabled))
    }
}

// MARK: - Notifications

@Suite("Fūrin notification")
struct FurinTests {
    @Test func neverRingsTwice() {
        #expect(Furin.notificationSound(appRings: true) == nil)
        #expect(Furin.notificationSound(appRings: false) != nil)
        #expect(!Furin.presentationOptions(appRings: true).contains(.sound))
        #expect(Furin.presentationOptions(appRings: false).contains(.sound))
        #expect(Furin.presentationOptions(appRings: true).contains(.banner))
    }

    @Test func soundIsBundled() {
        #expect(Bundle.main.url(forResource: "furin", withExtension: "caf") != nil)
    }
}

// MARK: - Export counts

@Suite("Export counts")
struct ExportCountTests {
    @Test func countsMatchTheRowsWithoutLoadingThem() throws {
        let container = try memoryContainer()
        let context = ModelContext(container)
        let now = Date.now
        let kitchen = UUID()
        for (i, (placeID, name)) in [(kitchen, "Kitchen"), (kitchen, "Kitchen"), (nil, "Hall"), (nil, "Porch")].enumerated() {
            context.insert(Reading(timestamp: now.addingTimeInterval(-Double(i) * 60), co2: 700, temperature: nil,
                                   humidity: nil, pm25: nil, placeID: placeID, placeName: name,
                                   settling: false, sensorName: "ALPSTUGA"))
        }
        context.insert(Reading(timestamp: now, co2: 700, temperature: nil, humidity: nil, pm25: nil, placeID: nil,
                               placeName: "Demo room", settling: false, sensorName: DemoSensor.name))
        try context.save()
        let since = now.addingTimeInterval(-3600)
        let rows = try Exporter.fetchRows(container: container, since: since, filter: .excludingDemo)
        let counts = try Exporter.counts(container: container, since: since, filter: .excludingDemo)
        #expect(counts.samples == rows.count)
        #expect(counts.places == Set(rows.map(\.placeKey)).count)
        #expect(counts.places == 3)
    }
}


@Suite("History gaps & scale")
struct HistoryGapTests {
    private func point(_ minutes: Double, _ value: Double = 500, segment: Int = 0) -> HistoryBody.ChartPoint {
        let t = Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60)
        return HistoryBody.ChartPoint(id: "\(minutes)", time: t, value: value, placeKey: "a", place: "A",
                                      segment: segment, isSingle: false)
    }

    @Test func gapsAppearOnlyWhereReadingsStop() {
        let points = [point(0), point(1), point(2), point(40, segment: 1), point(41, segment: 1)]
        let gaps = HistoryBody.gaps(points, threshold: 3 * 60)
        #expect(gaps.count == 1)
        #expect(gaps[0].from.time == points[2].time && gaps[0].to.time == points[3].time)
    }

    @Test func steadyTemperatureGetsBreathingRoom() {
        let d = HistoryBody.domain(for: [20.7, 20.8, 20.75])
        #expect(d.lowerBound < 20.7 && d.upperBound > 20.8)
        #expect(d.upperBound - d.lowerBound >= 0.8)
    }
}
