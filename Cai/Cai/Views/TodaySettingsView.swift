import SwiftUI

// Settings → Today (PR 5): a group after Personalization built from
// SettingsView's own pieces (settingsGroup, settingsSection, navRow), and the
// Tools sub-screen built on ManagementScreen like Secrets. Shown only while
// `TodayNavigation.isEnabled`.

/// What the Today group reads from disk. Refreshed when Settings appears;
/// nothing here watches files.
@MainActor
final class TodaySettingsModel: ObservableObject {
    @Published private(set) var skill: TodaySkill.Existing = .missing
    @Published private(set) var enabledCount = TodaySource.allCases.count
    /// From `runs.log`, so the refresh line survives a relaunch.
    @Published private(set) var loggedSeconds: Int?
    /// The last refused recording, cleared when a combo is kept.
    @Published var shortcutProblem: TodayShortcut.Problem?

    func refresh() {
        skill = TodaySkill.bundledURL.map { TodaySkill.inspect(TodaySkill.installURL, bundled: $0) } ?? .differs
        switch TodaySourceSettings.read() {
        case .missing: enabledCount = TodaySource.allCases.count
        case .enabled(let enabled): enabledCount = enabled.count
        case .unreadable: enabledCount = 0  // the run won't start until Tools saves a new file
        }
        loggedSeconds = Self.lastLoggedSeconds()
    }

    /// Reveals `priorities.md`, creating it from the template first, the way
    /// Context Snippets seeds `snippets.json`.
    func openPriorities() {
        let url = TodayStore.prioritiesURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: TodayStore.stateFolder, withIntermediateDirectories: true)
            try? TodayPriorities.starter.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: TodayStore.stateFolder.path)
    }

    /// "Last refresh took N min." plus when refreshes run, per the setting.
    /// `seconds` is nil before the first run, and then there is no line.
    static func refreshLine(seconds: Int?, policy: CaiSettings.TodayRefresh) -> String? {
        guard let seconds else { return nil }
        let took = seconds < 60 ? "under a minute" : "\(Int((Double(seconds) / 60).rounded())) min"
        let when = policy == .daily
            ? "Today refreshes the first time you open it each day, and when you press ⌘R."
            : "Today refreshes only when you press ⌘R."
        return "Last refresh took \(took). \(when)"
    }

    private static func lastLoggedSeconds() -> Int? {
        guard let text = try? String(contentsOf: TodayStore.runsLogURL, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            if let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
               let seconds = object["seconds"] as? Int {
                return seconds
            }
        }
        return nil
    }
}

extension SettingsView {
    /// The Today group. Settings has no keyboard footer, so neither does this.
    @ViewBuilder
    var todayGroup: some View {
        settingsGroup(title: "Today") {
            // Who Matters Most: the Context Snippets pattern. "Read docs ↗" stays
            // hidden until a Today docs page exists (Asís, round 4).
            settingsSection(title: "Who Matters Most") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("People and Slack channels that rank first. Edit the file; the next refresh uses it.")
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: todaySettings.openPriorities) {
                        Text("Open in Finder")
                            .font(.system(size: 11))
                            .foregroundColor(.caiPrimary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open priorities.md in Finder")
                    .help("Reveal priorities.md in Finder. Edit it in any editor.")
                }
            }

            settingsDivider

            navRow(label: "Tools", count: todaySettings.enabledCount, total: TodaySource.allCases.count, action: onShowTodayTools)

            settingsDivider

            todaySkillRow

            settingsDivider

            todayShortcutRow

            settingsDivider

            // Pickers built like Defaults → Translation.
            HStack {
                Text("Refresh")
                    .font(.system(size: 12))
                    .foregroundColor(.caiTextPrimary)
                Spacer()
                Picker("", selection: $settings.todayRefresh) {
                    ForEach(CaiSettings.TodayRefresh.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("When Today refreshes")
            }

            settingsDivider

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("First build reads the last:")
                        .font(.system(size: 12))
                        .foregroundColor(.caiTextPrimary)
                    Spacer()
                    Picker("", selection: $settings.todayLookbackDays) {
                        ForEach(CaiSettings.todayLookbackPresets, id: \.self) { days in
                            Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityLabel("How far the first build reads back")
                }
                Text("Later refreshes read only what changed since the previous one.")
                    .font(.system(size: 10))
                    .foregroundColor(.caiTextSecondary.opacity(0.6))
            }

            if let line = TodaySettingsModel.refreshLine(seconds: todayRunner.lastRunSeconds ?? todaySettings.loggedSeconds,
                                                         policy: settings.todayRefresh) {
                settingsDivider
                Text(line)
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { todaySettings.refresh() }
    }

    private var todaySkillRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("cai-today Skill")
                .font(.system(size: 12))
                .foregroundColor(.caiTextPrimary)
            Text(Self.skillLine(todaySettings.skill))
                .font(.system(size: 10))
                .foregroundColor(.caiTextSecondary.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func skillLine(_ existing: TodaySkill.Existing) -> String {
        switch existing {
        case .missing: return "Not in Claude yet. Setting up Today adds it."
        case .identical: return "Added to Claude, up to date"
        case .symlink: return "Added, and managed elsewhere (a link). Cai leaves it as it is."
        case .differs: return "A different version is there. Cai leaves it as it is."
        }
    }

    private var todayShortcutRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Today Shortcut")
                    .font(.system(size: 12))
                    .foregroundColor(.caiTextPrimary)
                Spacer()
                ShortcutRecorderView(target: .today, onProblem: { todaySettings.shortcutProblem = $0 })
                    .frame(width: 120, height: 24)
                    .accessibilityLabel("Today shortcut")
            }
            Text(todayShortcutLine)
                .font(.system(size: 10))
                .foregroundColor(.caiTextSecondary.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var todayShortcutLine: String {
        if let problem = todaySettings.shortcutProblem { return TodayShortcut.message(problem) }
        guard let today = settings.todayKeyCombo else {
            return "Opens Cai straight on Today. Try ⌥⌘C. \(TodayShortcut.note)"
        }
        if TodayShortcut.registered(today: today, main: settings.keyCombo) == nil {
            return "Off: it's the same as Cai's own shortcut. Pick another."
        }
        return TodayShortcut.note
    }
}

// MARK: - Tools sub-screen

/// The same rows and switches as setup step 2, saved to `sources.json` on
/// every switch. The probe runs on open and on "Check again".
@MainActor
final class TodayToolsModel: ObservableObject {
    @Published private(set) var tools: TodaySetup.Tools = .checking
    private var generation = 0

    var rows: [TodaySetup.ToolRow] {
        if case .ready(let rows) = tools { return rows }
        return []
    }

    /// The last report when there is one (from setup or an earlier visit);
    /// `claude` starts only when there is none, or on "Check again".
    func show() {
        if let report = TodayRunner.shared.lastToolsReport {
            tools = .ready(TodaySetup.rows(report, saved: TodaySourceSettings.load(), previous: []))
        } else {
            check()
        }
    }

    func check() {
        generation += 1
        let current = generation
        let previous = rows
        tools = .checking
        Task {
            let outcome = await TodayRunner.shared.probeTools()
            guard current == generation else { return }
            switch outcome {
            case .claudeMissing: tools = .failed("Claude Code isn't installed")
            case .failed(let reason): tools = .failed(reason)
            case .report(let report): tools = .ready(TodaySetup.rows(report, saved: TodaySourceSettings.load(), previous: previous))
            }
        }
    }

    /// The last switch on stays on: a run with no source reads nothing.
    func isLocked(_ row: TodaySetup.ToolRow) -> Bool {
        row.on && rows.filter(\.on).count == 1
    }

    /// Changes only the switched source in the saved set, so a source that
    /// is signed out right now keeps the choice the user made for it.
    func toggle(at index: Int) {
        guard case .ready(var rows) = tools, rows.indices.contains(index),
              rows[index].status == .connected, !isLocked(rows[index]) else { return }
        rows[index].on.toggle()
        tools = .ready(rows)
        var saved = TodaySourceSettings.load() ?? Set(TodaySource.allCases)
        if rows[index].on { saved.insert(rows[index].source) } else { saved.remove(rows[index].source) }
        TodaySourceSettings.save(saved)
    }
}

struct TodayToolsView: View {
    let onBack: () -> Void
    @StateObject private var model = TodayToolsModel()

    private enum Tab { case main }
    @State private var tab: Tab = .main

    var body: some View {
        ManagementScreen(
            icon: "sun.max",
            title: "Today Tools",
            subtitle: subtitle,
            tabs: [],
            selection: $tab,
            customTabId: nil,
            onAdd: nil
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    switch model.tools {
                    case .checking:
                        Text("Asking Claude which tools it can reach")
                            .font(.system(size: 11))
                            .foregroundColor(.caiTextSecondary)
                    case .failed(let reason):
                        Text("\(reason).")
                            .font(.system(size: 11))
                            .foregroundColor(.caiError)
                    case .ready(let rows):
                        ForEach(Array(rows.enumerated()), id: \.element.source) { index, row in
                            TodayToolRow(row: row, locked: model.isLocked(row)) { model.toggle(at: index) }
                        }
                        if TodaySourceSettings.read() == .unreadable {
                            Text("Cai can't read its saved tool choice, so Today won't refresh. Switch a tool to save it again.")
                                .font(.system(size: 11))
                                .foregroundColor(.caiTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button(action: model.check) {
                        Text("Check again")
                            .font(.system(size: 11))
                            .foregroundColor(.caiPrimary)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.tools == .checking)
                    .padding(.top, 4)
                    .help("Ask Claude which tools it can reach now")
                }
                .padding(16)
            }
        }
        .onAppear { model.show() }
    }

    private var subtitle: String {
        guard case .ready(let rows) = model.tools else { return "Today reads only your DMs, mentions and threads" }
        return "\(rows.filter(\.on).count) of \(rows.count) on · Today reads only your DMs, mentions and threads"
    }
}
