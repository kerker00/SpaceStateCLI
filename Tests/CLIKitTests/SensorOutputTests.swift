import Foundation
import SpaceAPI
import Testing
@testable import CLIKit

struct SensorOutputTests {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let target = Target(endpoint: URL(string: "https://space.example/api")!, name: "Space")

    private func snapshot(_ sensors: SpaceInfo.Sensors = .init()) -> Snapshot {
        Snapshot(target, info: SpaceInfo(name: "Space", state: .init(
            open: true, lastChange: nil, message: nil, triggerPerson: nil), sensors: sensors), now: now)
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(Output.json(value).utf8)) as? [String: Any])
    }

    private func sensors(_ value: Snapshot) throws -> [String: Any] {
        try #require(object(value)["sensors"] as? [String: Any])
    }

    private func readings(_ kind: String, in value: Snapshot) throws -> [[String: Any]] {
        try #require(sensors(value)[kind] as? [[String: Any]])
    }

    @Test func JSONPreservesSensorMetadataAndValueChangeTime() throws {
        let value = snapshot(.init(temperature: [.init(value: 21.5, unit: "°C", location: "Lab",
            name: "Desk", description: "Inside", lastChange: Date(timeIntervalSince1970: 100))]))
        let row = try #require(readings("temperature", in: value).first)
        #expect(row["value"] as? Double == 21.5)
        #expect(row["unit"] as? String == "°C")
        #expect(row["location"] as? String == "Lab")
        #expect(row["name"] as? String == "Desk")
        #expect(row["description"] as? String == "Inside")
        #expect(row["lastChange"] as? String == "1970-01-01T00:01:40Z")
        #expect(value.checkedAt == now)
    }

    @Test func JSONIncludesAllElevenTypedKinds() throws {
        let value = snapshot(.init(
            temperature: [.init(value: 20)], humidity: [.init(value: 50)],
            carbonDioxide: [.init(value: 600)], barometer: [.init(value: 1000)],
            doorLocked: [.init(value: false)], peopleNowPresent: [.init(value: 0)],
            totalMemberCount: [.init(value: 100)], networkConnections: [.init(value: 30)],
            beverageSupply: [.init(value: 12)], powerConsumption: [.init(value: 800)],
            powerGeneration: [.init(value: 200)]))
        #expect(Set(try sensors(value).keys) == ["temperature", "humidity", "carbondioxide", "barometer",
            "door_locked", "people_now_present", "total_member_count", "network_connections", "beverage_supply",
            "power_consumption", "power_generation"])
        #expect(try readings("door_locked", in: value).first?["value"] as? Bool == false)
        #expect(try readings("people_now_present", in: value).first?["value"] as? Int == 0)
        let text = Profile(value).text(color: false, now: now)
        #expect(text.contains("Door locked  false"))
        #expect(text.contains("Power generation  200"))
    }

    @Test func preservesGenericCompoundJSONWithoutInterpretingIt() throws {
        let value = snapshot(.init(other: [
            "wind": .array([.object(["properties": .object([
                "speed": .object(["value": .number(5), "unit": .string("m/s")])])])]),
            "radiation": .object(["alpha": .array([.object(["value": .number(0.1)])])]),
            "ext_values": .array([.boolean(true), .string("1"), .number(1), .null])]))
        let other = try #require(sensors(value)["other"] as? [String: Any])
        #expect(other["wind"] is [[String: Any]])
        #expect(other["radiation"] is [String: Any])
        let data = try #require(other["ext_values"] as? [Any])
        #expect(data[0] as? Bool == true)
        #expect(data[1] as? String == "1")
        #expect(data[2] as? Int == 1)
        #expect(data[3] is NSNull)
        #expect(Profile(value).text(color: false, now: now).contains("Other wind (uninterpreted)"))
        #expect(value.sensorSummary == nil)
    }

    @Test func compactOutputSelectsFirstReadingPerKindWithoutSummingVisitors() {
        let value = snapshot(.init(
            temperature: [.init(value: 21.5, unit: "°C", location: "Lab"), .init(value: 10, unit: "°C", location: "Outside")],
            humidity: [.init(value: 50, unit: "%")], carbonDioxide: [.init(value: 600, unit: "ppm")],
            peopleNowPresent: [.init(value: 3, location: "Lab"), .init(value: 5, location: "Workshop")]))
        #expect(value.sensorSummary == "visitors 3 (Lab) · temp 21.5 °C (Lab) · humidity 50 % · CO₂ 600 ppm")
        let text = Output.table([value], color: false, now: now)
        #expect(text.contains(value.sensorSummary!))
        #expect(!text.contains("Outside"))
        #expect(!text.contains("visitors 8"))
        let full = Profile(value).text(color: false, now: now)
        #expect(full.contains("Temperature  10 °C · location: Outside"))
        #expect(full.contains("Visitors  5 · location: Workshop"))
    }

    @Test func compactOutputDoesNotInventOrConvertUnits() throws {
        let fahrenheit = snapshot(.init(temperature: [.init(value: 68, unit: "°F", name: "Desk")]))
        #expect(fahrenheit.sensorSummary == "temp 68 °F (Desk)")
        #expect(!Output.table([fahrenheit], color: false, now: now).contains("°C"))
        let missing = snapshot(.init(temperature: [.init(value: 20)]))
        #expect(missing.sensorSummary == "temp 20")
        #expect(try readings("temperature", in: missing).first?["unit"] == nil)
    }

    @Test func absentSensorsRemainAbsentInTextAndEveryJSONShape() throws {
        let value = snapshot()
        #expect(value.sensors == nil)
        #expect(try object(value)["sensors"] == nil)
        #expect(try object(Profile(value))["sensors"] == nil)
        #expect(!Profile(value).text(color: false, now: now).contains("Sensors"))
        #expect(!Output.table([value], color: false, now: now).contains("temp"))
        #expect(!WatchState.changed(value, snapshot()))
    }

    @Test func zeroVisitorsAndFalseDoorsAreNotTreatedAsMissing() throws {
        let value = snapshot(.init(doorLocked: [.init(value: false)], peopleNowPresent: [.init(value: 0)]))
        #expect(value.sensorSummary == "visitors 0")
        let text = Profile(value).text(color: false, now: now)
        #expect(text.contains("Visitors  0"))
        #expect(text.contains("Door locked  false"))
        #expect(try readings("door_locked", in: value).count == 1)
    }

    @Test func malformedReadingsDoNotHideValidValuesOrOpening() throws {
        let info = try JSONDecoder().decode(SpaceInfo.self, from: Data(#"""
            {"space":"Space","state":{"open":true},"sensors":{
             "temperature":[{"value":"warm"},null,{"value":21.5,"unit":"°C","location":3}],
             "door_locked":[{"value":1},{"value":true}],"humidity":"bad"}}
            """#.utf8))
        let value = Snapshot(target, info: info, now: now)
        #expect(value.status == .open)
        #expect(try readings("temperature", in: value).count == 1)
        #expect(try readings("temperature", in: value).first?["location"] == nil)
        #expect(try readings("door_locked", in: value).first?["value"] as? Bool == true)
        #expect(try sensors(value)["humidity"] == nil)
        #expect(try sensors(value)["other"] == nil)
    }

    @Test func nonfiniteInjectedValuesCannotBreakJSONOrCreateCurrentText() throws {
        let value = snapshot(.init(temperature: [.init(value: .nan), .init(value: .infinity), .init(value: 21)],
                                   other: ["ext_raw": .object(["bad": .number(.infinity)])]))
        #expect(try readings("temperature", in: value).count == 1)
        #expect(value.sensorSummary == "temp 21")
        let raw = try #require(sensors(value)["other"] as? [String: Any])
        #expect((raw["ext_raw"] as? [String: Any])?["bad"] is NSNull)
        #expect(snapshot(.init(temperature: [.init(value: .nan)])).sensors == nil)
    }

    @Test func unusableSensorDatesAreOmittedWithoutRedatingReadings() throws {
        for seconds: TimeInterval in [.nan, .infinity, -1, 1e300] {
            let value = snapshot(.init(temperature: [.init(value: 21, lastChange: Date(timeIntervalSince1970: seconds))]))
            #expect(try readings("temperature", in: value).first?["lastChange"] == nil)
            #expect(value.checkedAt == now)
            #expect(!Profile(value).text(color: false, now: now).contains("changed:"))
        }
    }

    @Test func terminalControlsAndWaybarMarkupStayEscaped() throws {
        let value = snapshot(.init(temperature: [.init(value: 21.5, unit: "°C\n", location: "<Lab>&\u{1B}",
                                                        name: "Desk\t", description: "Line\nInjected")]))
        let table = Output.table([value], color: false, now: now)
        #expect(!table.contains("\n"))
        #expect(!table.contains("\u{1B}"))
        let tooltip = try #require(objectFromWaybar(value)["tooltip"] as? String)
        #expect(tooltip.contains("&lt;Lab&gt;&amp;"))
        #expect(!tooltip.contains("<Lab>"))
        #expect(!tooltip.contains("\u{1B}"))
        let json = try Output.json(value)
        #expect(!json.contains("\n"))
        #expect(try readings("temperature", in: value).first?["description"] as? String == "Line\nInjected")
        #expect(Profile(value).text(color: false, now: now).contains("description: Line Injected"))
    }

    @Test func staleAndUnprovenReadingsRemainHistoricalInInfoAndJSON() throws {
        let current = snapshot(.init(temperature: [.init(value: 21, lastChange: Date(timeIntervalSince1970: 9_999_999_999))]))
        let stale = current.evaluated(at: now.addingTimeInterval(900))
        #expect(stale.sensorSummary == nil)
        #expect(stale.status == .unknown)
        #expect(!Output.table([stale], color: false, now: now.addingTimeInterval(900)).contains("temp 21"))
        let text = Profile(stale).text(color: false, now: now.addingTimeInterval(900))
        #expect(text.contains("last known; stale observation"))
        #expect(text.contains("Temperature  21"))
        #expect(try readings("temperature", in: stale).first?["lastChange"] as? String != nil)
        let entry = DirectoryEntry(endpoint: target.endpoint, info: current.info!, lastSeen: nil)
        let unknown = Snapshot(entry, now: now)
        #expect(unknown.sensorSummary == nil)
        #expect(Profile(unknown).text(color: false, now: now).contains("last known; no current observation"))
        #expect(try readings("temperature", in: unknown).count == 1)
    }

    @Test func failedWatchReadRetainsSensorsAndTheirOriginalTimes() throws {
        let good = snapshot(.init(temperature: [.init(value: 21, lastChange: Date(timeIntervalSince1970: 100))]))
        var state = WatchState()
        _ = state.record([good])
        let attempted = now.addingTimeInterval(10)
        let failure = Snapshot(target, info: nil, error: "offline", now: attempted)
        let value = try #require(state.record([failure]).first)
        #expect(value.sensors == good.sensors)
        #expect(value.checkedAt == good.checkedAt)
        #expect(value.receivedAt == good.receivedAt)
        #expect(value.attemptedAt == attempted)
        #expect(value.sensorSummary == nil)
        #expect(value.status == .unknown)
        #expect(Profile(value).text(color: false, now: attempted).contains("last known; read failed"))
        #expect(try readings("temperature", in: value).first?["lastChange"] as? String == "1970-01-01T00:01:40Z")
    }

    @Test func watchDetectsDisplayedSensorChangesWithoutOpeningChanges() {
        let before = snapshot(.init(temperature: [.init(value: 20, unit: "°C")]))
        let after = snapshot(.init(temperature: [.init(value: 21, unit: "°C")]))
        #expect(before.status == after.status)
        #expect(WatchState.changed(before, after))
        #expect(Output.change(after, color: false, now: now).contains("temp 21 °C"))
        let visitors = snapshot(.init(peopleNowPresent: [.init(value: 1)]))
        #expect(WatchState.changed(visitors, snapshot(.init(peopleNowPresent: [.init(value: 2)]))))
    }

    @Test func irrelevantValuesAndChangeDatesDoNotRepeatCompactWatchLines() {
        let before = snapshot(.init(temperature: [.init(value: 20, lastChange: Date(timeIntervalSince1970: 10))],
                                    powerConsumption: [.init(value: 100)]))
        let after = snapshot(.init(temperature: [.init(value: 20, lastChange: Date(timeIntervalSince1970: 20))],
                                   powerConsumption: [.init(value: 200)]))
        #expect(!WatchState.changed(before, after))
        #expect(before.sensors != after.sensors)
    }

    @Test func removingACompactReadingOrExpiringItTriggersAWatchChange() {
        let before = snapshot(.init(peopleNowPresent: [.init(value: 0)]))
        #expect(WatchState.changed(before, snapshot()))
        let expired = before.evaluated(at: now.addingTimeInterval(900))
        #expect(WatchState.changed(before, expired))
        #expect(expired.sensorSummary == nil)
        #expect(expired.checkedAt == before.checkedAt)
    }

    @Test func sensorJSONIsIdenticalAcrossSnapshotProfileAndDirectorySearch() throws {
        let value = snapshot(.init(temperature: [.init(value: 21.5, unit: "°C")]))
        let profile = try #require(object(Profile(value))["sensors"] as? [String: Any])
        #expect(NSDictionary(dictionary: try sensors(value)).isEqual(to: profile))
        let entry = DirectoryEntry(endpoint: target.endpoint, info: value.info!, lastSeen: now)
        let search = try #require(JSONSerialization.jsonObject(with: Data(Output.searchJSON([entry]).utf8)) as? [[String: Any]])
        let searchSensors = try #require(search.first?["sensors"] as? [String: Any])
        #expect(NSDictionary(dictionary: profile).isEqual(to: searchSensors))
    }

    @Test func sensorsDoNotOverrideOpeningQuietCodesOrMissingSpaceState() {
        let value = snapshot(.init(doorLocked: [.init(value: true)], peopleNowPresent: [.init(value: 0)]))
        #expect(value.status == .open)
        #expect(Output.exitCode([value]) == 0)
        let noState = Snapshot(target, info: SpaceInfo(name: "Space", sensors: .init(
            temperature: [.init(value: 21)], peopleNowPresent: [.init(value: 10)])), now: now)
        #expect(noState.status == .unknown)
        #expect(Output.exitCode([noState]) == 2)
    }

    @Test func visitorSummaryUsesOneNonnegativeWholeCountAndNeverPersonNames() throws {
        let value = snapshot(.init(peopleNowPresent: [.init(value: -1), .init(value: 1.5),
                                                     .init(value: 5, location: "Lab"), .init(value: 8)]))
        #expect(value.sensorSummary == "visitors 5 (Lab)")
        #expect(try readings("people_now_present", in: value).count == 4)
        let info = try JSONDecoder().decode(SpaceInfo.self, from: Data(#"""
            {"space":"Space","sensors":{"people_now_present":[{"value":3,"names":["Hidden person"]}],
            "network_connections":[{"value":2,"machines":[{"name":"Hidden machine"}]}]}}
            """#.utf8))
        let encoded = try Output.json(Snapshot(target, info: info, now: now))
        #expect(!encoded.contains("Hidden"))
        #expect(!encoded.contains("machines"))
        #expect(!encoded.contains("names"))
    }

    @Test func infoShowsEveryReadingAndMetadataWithoutRepeatingCompactValues() {
        let value = snapshot(.init(temperature: [.init(value: 21.5, unit: "°C", location: "Lab", name: "Desk",
            description: "Inside", lastChange: Date(timeIntervalSince1970: 100)), .init(value: -10, unit: "°C", location: "Outside")]))
        let text = Profile(value).text(color: false, now: now)
        #expect(text.contains("Sensors"))
        #expect(text.contains("Temperature  21.5 °C · location: Lab · name: Desk · description: Inside · changed: 1970-01-01T00:01:40Z"))
        #expect(text.contains("Temperature  -10 °C · location: Outside"))
        #expect(!text.contains("temp 21.5"))
    }

    private func objectFromWaybar(_ value: Snapshot) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(Output.waybar(value, now: now).utf8)) as? [String: Any])
    }
}
