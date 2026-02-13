import AppKit
import Foundation

// MARK: - System Actions

/// Static helpers for executing non-LLM actions: open URLs, maps, calendar, search, clipboard.
struct SystemActions {

    // MARK: - Open URL

    static func openURL(_ url: URL) {
        // Ensure the URL has a scheme — NSWorkspace.open fails with -50 for scheme-less URLs
        if url.scheme == nil || url.scheme?.isEmpty == true {
            if let fixed = URL(string: "https://\(url.absoluteString)") {
                NSWorkspace.shared.open(fixed)
                return
            }
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Maps

    /// Opens an address in the user's preferred maps app (from Settings).
    static func openInMaps(_ address: String) {
        let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? address
        let provider = CaiSettings.shared.mapsProvider
        let urlString: String
        switch provider {
        case .apple:
            urlString = "maps://?q=\(encoded)"
        case .google:
            urlString = "https://www.google.com/maps/search/?api=1&query=\(encoded)"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Calendar Event (ICS)

    /// Creates a temporary .ics file and opens it with the default calendar app.
    /// Calendar.app shows a prefilled "Add Event" dialog — no EventKit permissions needed.
    static func createCalendarEvent(
        title: String,
        date: Date,
        duration: TimeInterval = 3600,
        location: String?,
        description: String? = nil
    ) {
        let endDate = date.addingTimeInterval(duration)

        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Cai//Cai//EN",
            "BEGIN:VEVENT",
            "DTSTART:\(formatICSDate(date))",
            "DTEND:\(formatICSDate(endDate))",
            "SUMMARY:\(escapeICS(title))"
        ]

        if let location = location {
            lines.append("LOCATION:\(escapeICS(location))")
        }
        if let description = description {
            lines.append("DESCRIPTION:\(escapeICS(description))")
        }

        lines.append(contentsOf: [
            "END:VEVENT",
            "END:VCALENDAR"
        ])

        let icsContent = lines.joined(separator: "\r\n")

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cai-event-\(UUID().uuidString).ics")

        do {
            try icsContent.write(to: tempURL, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(tempURL)

            // Clean up temp file after Calendar.app has had time to read it
            // (30s to handle slow launches or large calendars)
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                try? FileManager.default.removeItem(at: tempURL)
            }
        } catch {
            print("Failed to create ICS file: \(error)")
        }
    }

    private static func formatICSDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private static func escapeICS(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: - Search Web

    /// Opens a web search using the configured search URL from settings.
    static func searchWeb(_ query: String, searchBaseURL: String) {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        if let url = URL(string: searchBaseURL + encoded) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Clipboard

    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
