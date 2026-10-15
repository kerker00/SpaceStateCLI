import Foundation
import SpaceAPI

/// The same sensor payload is used by show, search, watch and info JSON.
/// Missing groups are omitted. Other sensor kinds remain explicitly uninterpreted.
public struct SensorOutput: Encodable, Hashable, Sendable {
    private enum Value: Encodable, Hashable, Sendable {
        case number(Double)
        case boolean(Bool)

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .number(let value): try container.encode(value)
            case .boolean(let value): try container.encode(value)
            }
        }

        var text: String {
            switch self {
            case .number(let value):
                if value == 0 { return "0" }
                let text = String(value)
                return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
            case .boolean(let value): return value ? "true" : "false"
            }
        }
    }

    private struct Reading: Encodable, Hashable, Sendable {
        let value: Value
        let unit: String?
        let location: String?
        let name: String?
        let description: String?
        let lastChange: Date?

        init<T>(_ sensor: SpaceInfo.Sensor<T>, value: Value) {
            self.value = value
            unit = sensor.unit
            location = sensor.location
            name = sensor.name
            description = sensor.description
            lastChange = sensor.lastChange.flatMap {
                let seconds = $0.timeIntervalSince1970
                return seconds.isFinite && (0...253_402_300_799).contains(seconds) ? $0 : nil
            }
        }

        var summary: String {
            let unit = unit.flatMap(Self.nonEmpty)
            let place = location.flatMap(Self.nonEmpty) ?? name.flatMap(Self.nonEmpty)
            return value.text + (unit.map { " \($0)" } ?? "") + (place.map { " (\($0))" } ?? "")
        }

        var details: String {
            var parts = [value.text + (unit.flatMap(Self.nonEmpty).map { " \($0)" } ?? "")]
            if let location = location.flatMap(Self.nonEmpty) { parts.append("location: \(location)") }
            if let name = name.flatMap(Self.nonEmpty) { parts.append("name: \(name)") }
            if let description = description.flatMap(Self.nonEmpty) { parts.append("description: \(description)") }
            if let lastChange { parts.append("changed: \(lastChange.ISO8601Format())") }
            return parts.joined(separator: " · ")
        }

        private static func nonEmpty(_ value: String) -> String? {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    private struct Group: Hashable, Sendable {
        let key: String
        let title: String
        let readings: [Reading]
    }

    private let groups: [Group]
    private let other: [String: SpaceInfo.SensorData]

    init?(_ sensors: SpaceInfo.Sensors) {
        func numeric(_ key: String, _ title: String, _ values: [SpaceInfo.Sensor<Double>]) -> Group {
            Group(key: key, title: title, readings: values.filter { $0.value.isFinite }.map {
                Reading($0, value: .number($0.value))
            })
        }
        groups = [
            numeric("temperature", "Temperature", sensors.temperature),
            numeric("humidity", "Humidity", sensors.humidity),
            numeric("carbondioxide", "CO₂", sensors.carbonDioxide),
            numeric("barometer", "Pressure", sensors.barometer),
            Group(key: "door_locked", title: "Door locked", readings: sensors.doorLocked.map {
                Reading($0, value: .boolean($0.value))
            }),
            numeric("people_now_present", "Visitors", sensors.peopleNowPresent),
            numeric("total_member_count", "Members", sensors.totalMemberCount),
            numeric("network_connections", "Network connections", sensors.networkConnections),
            numeric("beverage_supply", "Beverages", sensors.beverageSupply),
            numeric("power_consumption", "Power consumption", sensors.powerConsumption),
            numeric("power_generation", "Power generation", sensors.powerGeneration),
        ].filter { !$0.readings.isEmpty }
        other = sensors.other
        if groups.isEmpty && other.isEmpty { return nil }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        for group in groups { try container.encode(group.readings, forKey: Key(group.key)) }
        if !other.isEmpty {
            try container.encode(other.mapValues(Raw.init), forKey: Key("other"))
        }
    }

    /// At most the first reading of each preferred kind, retaining its published
    /// unit and location/name. Do not sum overlapping visitor counters.
    var compact: String? {
        let preferences = [("people_now_present", "visitors"), ("temperature", "temp"),
                           ("humidity", "humidity"), ("carbondioxide", "CO₂")]
        let parts = preferences.compactMap { key, label -> String? in
            let readings = groups.first { $0.key == key }?.readings ?? []
            let reading = readings.first { reading in
                if key != "people_now_present" { return true }
                guard case .number(let count) = reading.value else { return false }
                return count >= 0 && count.rounded() == count
            }
            return reading.map { "\(label) \($0.summary)" }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var lines: [String] {
        groups.flatMap { group in group.readings.map { "\(group.title)  \($0.details)" } }
        + other.keys.sorted().compactMap { key in
            (try? Output.json(Raw(other[key]!))).map { "Other \(key) (uninterpreted)  \($0)" }
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private struct Raw: Encodable {
        let data: SpaceInfo.SensorData
        init(_ data: SpaceInfo.SensorData) { self.data = data }
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch data {
            case .number(let number):
                if number.isFinite { try container.encode(number) } else { try container.encodeNil() }
            case .boolean(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .array(let values): try container.encode(values.map(Raw.init))
            case .object(let values): try container.encode(values.mapValues(Raw.init))
            case .null: try container.encodeNil()
            }
        }
    }
}
