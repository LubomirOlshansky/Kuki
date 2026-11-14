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
        #expect(EnsoRing.fraction(for: 0) == 0.06)
        #expect(EnsoRing.fraction(for: 400) == 0.06)
        #expect(EnsoRing.fraction(for: 10_000) == 0.94)
        #expect(abs(EnsoRing.fraction(for: 1200) - 0.5) < 0.0001)
    }

    @Test func motesGrowWithCO2() {
        #expect(AirMotes.count(for: 400) == 6)
        #expect(AirMotes.count(for: 2000) == 90)
        #expect(AirMotes.count(for: 9000) == 90)
        let samples = stride(from: 400.0, through: 2000, by: 100).map(AirMotes.count)
        #expect(samples == samples.sorted())
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
    @Test func newSegmentOnMoveOrGap() {
        let rows = [row(0, "Kitchen"), row(1, "Kitchen"),      // visit 1
                    row(2, "Bedroom"),                         // move → visit 2
                    row(3, "Kitchen"),                         // move back → visit 3
                    row(200, "Kitchen")]                       // app was closed → visit 4
        let points = HistoryBody.segments(rows, gap: 15 * 60)
        #expect(points.map(\.segment) == [0, 0, 1, 2, 3])
        #expect(points.map(\.isSingle) == [false, false, true, true, true], "lone points are drawn as dots")
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
        CloudWake.alertIfNeeded(s, now: t, defaults: defaults)
        let gate = try JSONDecoder().decode(AlertGate.self, from: try #require(defaults.data(forKey: "cloudAlertGate")))
        #expect(gate.lastAlertAt == t, "rang once")
        CloudWake.alertIfNeeded(s, now: t.addingTimeInterval(60), defaults: defaults)
        let gate2 = try JSONDecoder().decode(AlertGate.self, from: try #require(defaults.data(forKey: "cloudAlertGate")))
        #expect(gate2.lastAlertAt == t, "stays quiet while still stuffy")
    }
}
