import Foundation

/// Wire-format constants and hard limits for authored actions.
///
/// Both sides of the file handoff read these: the helper stamps
/// `ActionSchema.version` onto every pending change it writes, the app refuses
/// anything it doesn't recognize. Bump the version only for a breaking shape
/// change; additive optional fields don't need one (they decode as nil).
public enum ActionSchema {

    /// Schema version stamped on every pending-change file.
    public static let version = 1

    /// Versions this build can ingest. A file outside the set is quarantined
    /// with a legible reason rather than best-effort decoded, so a newer
    /// helper paired with an older app fails loudly instead of silently
    /// dropping fields the user thinks they approved.
    public static let supportedVersions: Set<Int> = [1]

    /// Action name bounds. Matches what the shortcuts editor accepts and what
    /// the action list can render on one row.
    public static let minNameLength = 1
    public static let maxNameLength = 60

    /// Scalar ceiling for a name, alongside the grapheme cap above.
    /// `String.count` counts graphemes, and one grapheme stacks arbitrarily
    /// many combining marks: `"A"` plus 5,000 acute accents is one character
    /// by that measure and 10 KB of scalars, bounded only by
    /// `maxPendingFileBytes`. The approval sheet renders a name in a
    /// `lineLimit(1)` row, so the cost lands as CoreText layout on the one
    /// surface that must stay responsive.
    ///
    /// Ten times the grapheme cap, counted on the folded, NFC name. Sized so
    /// that **no** legitimate name can trip it and the cap means exactly one
    /// thing: deliberate mark stacking. Measured scalars per grapheme, all of
    /// which now reach this check intact because emoji clusters survive the
    /// strip whole: 2 for a regional-indicator flag or an emoji plus skin-tone
    /// modifier, 2 to 4 for Devanagari and Thai clusters, 5 for a family ZWJ
    /// sequence, 7 for a subdivision flag, and 10 for the worst RGI sequence
    /// there is (kiss with two skin tones). Ten times the grapheme cap
    /// therefore covers a full 60-grapheme name of the very worst case.
    ///
    /// A tighter multiple would refuse absurd-but-honest names instead, which
    /// is a worse trade: the attack this exists to stop is ~1 MB of combining
    /// marks on one grapheme, and 600 scalars is still three orders of
    /// magnitude below that.
    public static let maxNameScalars = 600

    /// Action value (prompt text, URL template, or shell command) bounds.
    public static let minValueLength = 1
    public static let maxValueLength = 10_000

    /// Max chain steps on an authored action. Mirrors `ChainExecutor.maxDepth`
    /// so an action that validates here can't blow the executor's depth cap on
    /// its first run.
    public static let maxChainSteps = 10

    /// Max pending changes held at once. Beyond this the queue is full and new
    /// proposals are rejected: approval is one-at-a-time and human, so an agent
    /// looping on create_action must hit a wall rather than bury the user.
    public static let maxPendingChanges = 50

    /// Bounds on provenance labels. They are attacker-controlled text rendered
    /// inside the approval sheet, so they follow the same limit as a name.
    public static let maxProvenanceLabelLength = 60

    /// Max audit-log entries kept in `action-history.json`. Oldest are dropped
    /// past this; the log is a revert aid, not an archive.
    public static let maxAuditEntries = 1_000

    /// Byte ceiling for the audit log. An entry carries full before and after
    /// snapshots, so 1,000 of them can reach hundreds of megabytes, and the
    /// whole file is rewritten on every decision. Oldest entries are dropped
    /// until the file fits.
    public static let maxAuditBytes = 5_000_000

    /// Files examined in one scan of the pending directory. The queue cap is
    /// applied after reading, so without this a directory stuffed with
    /// thousands of files would be read in full on the main actor before any
    /// of them could be refused.
    public static let maxPendingFilesScanned = 200

    /// Largest pending file the app will read. A valid proposal is a few KB
    /// (the value cap alone is 10K characters); anything past 1 MB is either
    /// broken or an attempt to make the app read a huge file into memory, and
    /// is quarantined without being read.
    public static let maxPendingFileBytes = 1_048_576

    /// Max refused proposals kept in `quarantine/`, oldest dropped first.
    /// The queue and the audit log are both capped; without this the one
    /// directory a misbehaving writer can fill grows until the disk does.
    /// 200 keeps plenty of forensic tail while bounding it at ~200 MB worst
    /// case (`maxPendingFileBytes` each).
    public static let maxQuarantinedFiles = 200
}
