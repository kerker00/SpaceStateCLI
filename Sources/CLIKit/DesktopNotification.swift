import Foundation
import SpacePushClient

/// Desktop notifications for SpacePush change events, shown through `notify-send`
/// (libnotify 0.8 or later, for `--print-id` and `--replace-id`).
public enum DesktopNotification {
    public static let defaultServer = "https://push.grafixmafia.net"

    public static func text(_ change: StateChange) -> (summary: String, body: String) {
        let name = Output.plain(change.name)
        guard change.kind == .change, let state = change.to else {
            return (name, "Test notification from SpacePush. This is not a status change.")
        }
        return (name, description(state))
    }

    /// The same meanings as the SpaceState apps' `PUSH_STATE_*` texts.
    public static func description(_ state: String) -> String {
        switch state {
        case "open": "Open"
        case "closed": "Closed"
        case "keyholder": "Keyholder present"
        case "member": "Open for members"
        case "open_plus": "Open+"
        case "closing": "Closing soon"
        default: Output.plain(state)
        }
    }

    /// Arguments for `notify-send`; `replacing` is the id of this topic's previous notification.
    public static func arguments(summary: String, body: String, replacing id: UInt32?) -> [String] {
        var arguments = ["--app-name=SpaceState", "--print-id"]
        if let id { arguments.append("--replace-id=\(id)") }
        // "--" keeps a name that starts with "-" from being read as an option.
        return arguments + ["--", summary, body]
    }

    /// The id `notify-send --print-id` printed.
    public static func id(fromOutput output: String) -> UInt32? {
        UInt32(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Stream subscriptions for the targets; a target is always the space itself.
    public static func subscriptions(_ targets: [Target]) -> [PushSubscription] {
        targets.map { PushSubscription(endpoint: $0.endpoint) }
    }
}
