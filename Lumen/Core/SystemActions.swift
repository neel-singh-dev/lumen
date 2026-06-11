import AppKit
import EventKit

/// System-side agent verbs — reminders via EventKit, notes via the Notes
/// scripting interface. Explicit-ask only (the prompt enforces it), spoken
/// before they run, and logged like every other action: the same trust
/// protocol as [OPEN]/[LAUNCH], extended by two verbs.
enum SystemActions {
    private static let eventStore = EKEventStore()

    static func saveReminder(_ text: String) async -> Bool {
        let granted = (try? await eventStore.requestFullAccessToReminders()) ?? false
        guard granted else { return false }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = text
        reminder.calendar = eventStore.defaultCalendarForNewReminders()
        return (try? eventStore.save(reminder, commit: true)) != nil
    }

    /// Notes has no public API; the scripting bridge is the front door.
    /// Must run on the main thread (NSAppleScript requirement).
    @MainActor
    static func saveNote(title: String, body: String) -> Bool {
        func escaped(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let source = """
        tell application "Notes"
            make new note at folder "Notes" of default account \
        with properties {name:"\(escaped(title))", body:"\(escaped(body))"}
        end tell
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return result != nil && error == nil
    }
}
