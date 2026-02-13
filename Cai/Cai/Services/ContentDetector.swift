import Foundation

// MARK: - Models

enum ContentType: String, Codable {
    case url
    case json
    case address
    case meeting   // Date/time detected via NSDataDetector
    case word      // 1-2 words, <30 chars
    case shortText // <100 chars
    case longText  // ≥100 chars
}

struct ContentEntities {
    var url: String?
    var address: String?
    var date: Date?
    var dateText: String?
    var location: String?
}

struct ContentResult {
    let type: ContentType
    let confidence: Double
    let entities: ContentEntities
}

// MARK: - ContentDetector

class ContentDetector {

    static let shared = ContentDetector()

    private init() {}

    /// Main detection entry point. Runs detectors in priority order and short-circuits on first match.
    func detect(_ text: String) -> ContentResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return ContentResult(type: .shortText, confidence: 1.0, entities: ContentEntities())
        }

        // Priority 1: URL
        if let result = detectURL(trimmed) { return result }

        // Priority 2: JSON
        if let result = detectJSON(trimmed) { return result }

        // Priority 3–5: Address, Meeting, Venue — only for short text (≤200 chars).
        // Long text that happens to contain a date or address should be treated as text,
        // not as a meeting/address. Users would select just the relevant portion for that.
        if trimmed.count <= 200 {
            // Priority 3: Address (street patterns + NSDataDetector)
            if let result = detectAddress(trimmed) { return result }

            // Priority 4: Date/Meeting
            if let result = detectMeeting(trimmed) { return result }

            // Priority 5: Venue / place name ("at Cafe La Palma", "in Ramones Bar")
            // Runs after meeting so that date-bearing text gets the richer meeting result.
            if let result = detectVenue(trimmed) { return result }
        }

        // Priority 6: Text classification (always succeeds)
        return classifyText(trimmed)
    }

    // MARK: - URL Detection (Priority 1)

    func detectURL(_ text: String) -> ContentResult? {
        // Pattern: https?://[^\s]+ or www.[^\s]+
        let urlPattern = #"(?:https?://|www\.)[^\s]+"#

        guard let regex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        if let match = regex.firstMatch(in: text, range: range) {
            var urlString = String(text[Range(match.range, in: text)!])

            // Ensure www. URLs have a protocol
            if urlString.hasPrefix("www.") {
                urlString = "https://" + urlString
            }

            var entities = ContentEntities()
            entities.url = urlString
            return ContentResult(type: .url, confidence: 1.0, entities: entities)
        }

        return nil
    }

    // MARK: - JSON Detection (Priority 2)

    func detectJSON(_ text: String) -> ContentResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Quick check: must start with { or [
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else {
            return nil
        }

        // Try parsing as-is first
        if isValidJSON(trimmed) {
            return ContentResult(type: .json, confidence: 1.0, entities: ContentEntities())
        }

        // Try removing trailing comma (common copy-paste artifact)
        let cleaned = trimmed.replacingOccurrences(
            of: #"([}\]])\s*,\s*$"#,
            with: "$1",
            options: .regularExpression
        )

        if isValidJSON(cleaned) {
            return ContentResult(type: .json, confidence: 1.0, entities: ContentEntities())
        }

        return nil
    }

    private func isValidJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    // MARK: - Address Detection (Priority 3)

    func detectAddress(_ text: String) -> ContentResult? {
        // International street address patterns:
        // Pattern 1: Number + name + street type suffix (English, Spanish, German, Dutch)
        //   e.g. "123 Main Street", "42 Calle Mayor", "15 Berliner Strasse", "23 Hauptstrasse"
        //   Note: German compounds like "Hauptstrasse" have the suffix embedded, so we use
        //   a word-ending match (\w*suffix\b) instead of requiring a word boundary before.
        let suffixPattern = #"(?i)\d{1,5}[,\s]+[\w\s]+\w*(?:street|st|avenue|ave|road|rd|boulevard|blvd|drive|dr|lane|ln|way|court|ct|place|pl|calle|c/|avenida|avda|paseo|plaza|rue|straße|strasse|str|gasse|platz|weg|piazza|corso|viale|largo|rua|praça|travessa|alameda|laan|straat|plein)\b"#

        // Pattern 2: Number + street-type-prefix + name (Italian, French, Portuguese)
        //   e.g. "7 Via Roma", "12 Rue de la Paix", "5 Rua das Flores"
        let prefixPattern = #"(?i)\d{1,5}[,\s]+(?:via|rue|rua|piazza|corso|viale|largo|praça|travessa|alameda|calle|avenida|paseo|plaza)\s+[\w\s]+"#

        let patterns = [suffixPattern, prefixPattern]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                var entities = ContentEntities()
                entities.address = text
                return ContentResult(type: .address, confidence: 0.8, entities: entities)
            }
        }

        // Backup: try NSDataDetector with .address type.
        // Require at least 2 recognized components to avoid false positives
        // (NSDataDetector is very loose — it matches random text as "addresses").
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = detector.firstMatch(in: text, range: range),
               let components = match.addressComponents {
                let parts = [
                    components[.street],
                    components[.city],
                    components[.state],
                    components[.zip],
                    components[.country]
                ].compactMap { $0 }
                if parts.count >= 2 {
                    var entities = ContentEntities()
                    entities.address = parts.joined(separator: ", ")
                    return ContentResult(type: .address, confidence: 0.8, entities: entities)
                }
            }
        }

        return nil
    }

    // MARK: - Date/Meeting Detection (Priority 4)

    func detectMeeting(_ text: String) -> ContentResult? {
        // Preprocess: convert European time formats (14h → 14:00, 9h30 → 9:30)
        var processed = text.replacingOccurrences(
            of: #"\b(\d{1,2})h(\d{2})\b"#,
            with: "$1:$2",
            options: .regularExpression
        )
        processed = processed.replacingOccurrences(
            of: #"\b(\d{1,2})h\b"#,
            with: "$1:00",
            options: .regularExpression
        )

        // Filter: skip if text is primarily a currency value
        let currencyPattern = #"^[\s]*[$€£¥#]\s*\d"#
        if let currencyRegex = try? NSRegularExpression(pattern: currencyPattern),
           currencyRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return nil
        }

        // Filter: skip duration patterns like "for 5 minutes", "about 2 hours"
        let durationPattern = #"(?i)^(?:for|about|around|approximately|~)\s+\d+\s+(?:seconds?|minutes?|mins?|hours?|hrs?|days?|weeks?|months?|years?)\b"#
        if let durationRegex = try? NSRegularExpression(pattern: durationPattern),
           durationRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return nil
        }

        // Use NSDataDetector to find dates
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }

        let range = NSRange(processed.startIndex..., in: processed)
        guard let match = detector.firstMatch(in: processed, range: range),
              let matchRange = Range(match.range, in: processed) else {
            return nil
        }

        // Filter: skip if the matched text is preceded by a currency symbol in the original
        if match.range.location > 0 {
            let beforeIndex = processed.index(processed.startIndex, offsetBy: match.range.location - 1)
            let charBefore = processed[beforeIndex]
            if "$€£¥#".contains(charBefore) {
                return nil
            }
        }

        var entities = ContentEntities()
        entities.date = match.date
        entities.dateText = String(processed[matchRange])

        // Look for meeting context keywords
        let meetingKeywords = ["meet", "meeting", "lunch", "dinner", "breakfast", "coffee", "call", "sync", "chat", "standup", "stand-up", "huddle", "catchup", "catch-up", "1:1", "one-on-one"]
        let lowered = text.lowercased()
        let hasMeetingContext = meetingKeywords.contains { lowered.contains($0) }

        // Extract location: reuse shared venue name extractor
        if let venueName = extractVenueName(text) {
            entities.location = venueName
        }

        let confidence: Double = hasMeetingContext ? 0.9 : 0.7
        return ContentResult(type: .meeting, confidence: confidence, entities: entities)
    }

    // MARK: - Venue / Place Name Detection (Priority 5)

    /// Detects short venue references like "at Cafe La Palma" or "in Ramones Bar".
    /// Place name must start with an uppercase letter to avoid false positives on
    /// common phrases ("at home", "in the morning").
    func detectVenue(_ text: String) -> ContentResult? {
        guard let name = extractVenueName(text) else { return nil }
        var entities = ContentEntities()
        entities.address = name
        entities.location = name
        return ContentResult(type: .address, confidence: 0.6, entities: entities)
    }

    /// Shared helper: extracts a venue/place name from "at [Name]" or "in [Name]" patterns.
    /// Case-sensitive on the place name (must start uppercase) to filter out noise.
    private func extractVenueName(_ text: String) -> String? {
        // Capture the preposition (group 1) and the place name (group 2).
        // "at/in" case-insensitive, place name must start with uppercase letter.
        let pattern = #"(?:^|\b)([Aa][Tt]|[Ii][Nn])\s+([A-Z][\w\s'&-]+?)(?:\s*[,.!?]|\s+(?:on|at|from|to|for)\b|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 2,
              let prepRange = Range(match.range(at: 1), in: text),
              let nameRange = Range(match.range(at: 2), in: text) else {
            return nil
        }
        let candidate = String(text[nameRange]).trimmingCharacters(in: .whitespaces)

        // Skip time-of-day words
        let timeWords = ["noon", "midnight", "night", "morning", "evening", "afternoon"]
        guard !timeWords.contains(candidate.lowercased()) else { return nil }

        // Skip if "in"/"at" is part of a phrasal verb/adjective (e.g. "built in", "log in",
        // "check in", "plug in", "opt in", "look at", "good at"). Check the word before.
        let prepStart = prepRange.lowerBound
        if prepStart > text.startIndex {
            // Walk back past whitespace to find the preceding word
            var idx = text.index(before: prepStart)
            while idx > text.startIndex && text[idx].isWhitespace {
                idx = text.index(before: idx)
            }
            if !text[idx].isWhitespace {
                // Find start of preceding word
                var wordStart = idx
                while wordStart > text.startIndex {
                    let prev = text.index(before: wordStart)
                    if text[prev].isWhitespace || text[prev].isPunctuation { break }
                    wordStart = prev
                }
                let prevWord = String(text[wordStart...idx]).lowercased()
                let phrasalPrefixes = [
                    "built", "log", "plug", "opt", "check", "sign", "fill", "turn",
                    "bring", "come", "give", "hand", "kick", "let", "move", "put",
                    "run", "set", "step", "take", "trade", "tune", "write",
                    "good", "bad", "interested", "involved", "included", "results"
                ]
                if phrasalPrefixes.contains(prevWord) { return nil }
            }
        }

        return candidate
    }

    // MARK: - Text Classification (Fallback — Priority 6)

    func classifyText(_ text: String) -> ContentResult {
        let words = text.split(separator: " ")
        let wordCount = words.count
        let charCount = text.count

        let type: ContentType
        if wordCount <= 2 && charCount < 30 {
            type = .word
        } else if charCount < 100 {
            type = .shortText
        } else {
            type = .longText
        }

        return ContentResult(type: type, confidence: 1.0, entities: ContentEntities())
    }
}
