import Combine
import Contacts
import SwiftUI

/// Today's first-run setup: add the skill, pick the tools, the first build,
/// then "Who matters most". A singleton, not view state: the build keeps
/// going when the panel closes, and Today reopens on the step it left.
/// `TodayScreenState` routes the panel's keys here while a step shows.
@MainActor
final class TodaySetup: ObservableObject {
    static let shared = TodaySetup()

    enum Step: Equatable { case intro, skill, tools, building, people }

    struct ToolRow: Equatable {
        let source: TodaySource
        var status: TodaySourceStatus
        var on: Bool
    }

    enum Tools: Equatable {
        case checking
        case ready([ToolRow])
        case failed(String)
    }

    @Published private(set) var step: Step?
    @Published private(set) var skill: TodaySkill.Existing = .missing
    @Published private(set) var skillError: String?
    @Published private(set) var tools: Tools = .checking
    @Published private(set) var toolIndex = 0
    @Published private(set) var building: [TodaySource] = []
    @Published private(set) var entries: [TodayPriorityEntry] = []
    @Published private(set) var entryIndex = 0
    @Published private(set) var addText = ""
    @Published private(set) var suggestionIndex = 0

    private var proposal: [TodayPriorityEntry] = []
    private var candidates: [TodaySuggestion] = []
    private var removed: [(entry: TodayPriorityEntry, index: Int)] = []
    private var probeGeneration = 0
    private var sawRun = false
    private var runnerWatch: AnyCancellable?
    private var runner: TodayRunner { .shared }

    private init() {
        runnerWatch = TodayRunner.shared.$phase.sink { [weak self] phase in
            Task { @MainActor in self?.runnerChanged(phase) }
        }
    }

    var suggestions: [TodaySuggestion] {
        addText.isEmpty ? [] : TodayPriorities.suggestions(for: addText, in: candidates, excluding: entries)
    }

    var enabledCount: Int {
        if case .ready(let rows) = tools { return rows.filter(\.on).count }
        return 0
    }

    /// Opening Today: setup reopens on the step it left, however long the
    /// panel was closed. A tool check that finished meanwhile shows its
    /// result, since the step it reports to is still there.
    func resume(listMissing: Bool) {
        step = Self.resumedStep(current: step, listMissing: listMissing)
    }

    /// A step in progress (skill, tools, building, people) is kept. With no
    /// step, or at the intro, Today offers setup only while there is no list.
    nonisolated static func resumedStep(current: Step?, listMissing: Bool) -> Step? {
        switch current {
        case .skill, .tools, .building, .people: return current
        case .intro, nil: return listMissing ? .intro : nil
        }
    }

    /// What the action list's notice strip says about Today, if anything:
    /// a first build still running, or setup left unfinished. A refresh of
    /// an existing list (⌘R) is not announced.
    var pending: ActionListNotice.TodayPending? {
        Self.pending(step: step, building: runner.isRunning)
    }

    nonisolated static func pending(step: Step?, building: Bool) -> ActionListNotice.TodayPending? {
        switch step {
        case .building: return building ? .building : .unfinished
        case .skill, .tools, .people: return .unfinished
        case .intro, nil: return nil
        }
    }

    // MARK: - Keys

    /// ↵ and ⌘↵: the step's default button.
    func enter() {
        switch step {
        case .intro: openSkillStep()
        case .skill: continueFromSkill()
        case .tools: startBuild()
        case .building: if case .failed = runner.phase { startBuild() }
        case .people: addText.isEmpty ? showToday() : add()
        case nil: break
        }
    }

    /// Esc. Returns false when Today should go back (or close) itself: from
    /// the intro, during the build (which keeps going), and from step 4,
    /// which first saves the list as it stands.
    func esc() -> Bool {
        switch step {
        case .skill:
            step = .intro
        case .tools:
            probeGeneration += 1
            step = .skill
        case .people where !addText.isEmpty:
            addText = ""
            suggestionIndex = 0
        case .people:
            save()
            return false
        case .intro, .building, nil:
            return false
        }
        return true
    }

    func move(by delta: Int) {
        switch step {
        case .tools:
            if case .ready(let rows) = tools, !rows.isEmpty { toolIndex = Self.wrap(toolIndex + delta, rows.count) }
        case .people:
            if !addText.isEmpty {
                let count = suggestions.count
                if count > 0 { suggestionIndex = Self.wrap(suggestionIndex + delta, count) }
            } else if !entries.isEmpty {
                entryIndex = Self.wrap(entryIndex + delta, entries.count)
            }
        default: break
        }
    }

    func type(_ character: String) {
        if character == " " {
            if step == .tools { return toggle(at: toolIndex) }
            if step == .people, addText.isEmpty { return toggleStar(at: entryIndex) }
        }
        guard step == .people, addText.count < TodayCandidates.maxField else { return }
        addText.append(character)
        suggestionIndex = 0
    }

    func backspace() {
        guard step == .people, !addText.isEmpty else { return }
        addText.removeLast()
        suggestionIndex = 0
    }

    /// Today's ⌘ keys during setup: ⌘R checks the tools again, ⌘⌫ and ⌘Z
    /// remove and restore in step 4, ⌘↵ is ↵. The rest do nothing here.
    func command(_ command: TodayCommand) {
        switch (command, step) {
        case (.copyAndClose, _): enter()
        case (.refresh, .tools): checkTools()
        case (.dismiss, .people) where addText.isEmpty: remove(at: entryIndex)
        case (.undo, .people): undoRemove()
        default: break
        }
    }

    // MARK: - Step 1: the skill

    func openSkillStep() {
        skillError = nil
        if let bundled = TodaySkill.bundledURL {
            skill = TodaySkill.inspect(TodaySkill.installURL, bundled: bundled)
        } else {
            skillError = "This copy of Cai is missing the skill. Reinstall Cai."
        }
        step = .skill
    }

    func continueFromSkill() {
        guard let bundled = TodaySkill.bundledURL else { return }
        do {
            if try TodaySkill.addIfSafe(bundled: bundled, to: TodaySkill.installURL) == .install {
                skill = .identical
                ToastQueue.post("Added to Claude", outcome: .success)
            }
        } catch {
            skillError = "Couldn't add the skill: \(error.localizedDescription)"
            return
        }
        step = .tools
        checkTools()
    }

    // MARK: - Step 2: tools

    func checkTools() {
        probeGeneration += 1
        let generation = probeGeneration
        let previous: [ToolRow] = { if case .ready(let rows) = tools { return rows } else { return [] } }()
        tools = .checking
        Task {
            let outcome = await runner.probeTools()
            guard generation == probeGeneration, step == .tools else { return }
            switch outcome {
            case .claudeMissing: tools = .failed("Claude Code isn't installed")
            case .failed(let reason): tools = .failed(reason)
            case .report(let report): tools = .ready(Self.rows(report, saved: TodaySourceSettings.load(), previous: previous))
            }
            toolIndex = 0
        }
    }

    /// Every known source in a fixed order. A connected source is on unless
    /// the user turned it off on this screen before ⌘R, or in an earlier
    /// setup (`sources.json`). A source that only now connected follows the
    /// saved file, so turning on something new is always the user's call.
    static func rows(_ report: TodayRunner.ToolsReport, saved: Set<TodaySource>?, previous: [ToolRow]) -> [ToolRow] {
        let servers = report.connectors.map { (name: $0.name, status: $0.status) }
        return TodaySource.allCases.map { source in
            let status = TodaySourceStatus.of(source, servers: servers, ghSignedIn: report.ghSignedIn)
            let wanted: Bool
            if let earlier = previous.first(where: { $0.source == source }), earlier.status == .connected {
                wanted = earlier.on
            } else {
                wanted = saved?.contains(source) ?? true
            }
            return ToolRow(source: source, status: status, on: status == .connected && wanted)
        }
    }

    func toggle(at index: Int) {
        guard case .ready(var rows) = tools, rows.indices.contains(index), rows[index].status == .connected else { return }
        toolIndex = index
        rows[index].on.toggle()
        tools = .ready(rows)
    }

    // MARK: - Step 3: the first build

    func startBuild() {
        if step == .tools {
            guard case .ready(let rows) = tools else { return }
            let enabled = rows.filter(\.on).map(\.source)
            guard !enabled.isEmpty else { return }
            TodaySourceSettings.save(Set(enabled))
            building = enabled
        }
        step = .building
        runner.start()
        sawRun = runner.isRunning
    }

    /// Back from a failed build.
    func backToTools() {
        step = .tools
        checkTools()
    }

    private func runnerChanged(_ phase: TodayRunner.Phase) {
        guard step == .building else { return }
        switch phase {
        case .running: sawRun = true
        case .idle where sawRun:
            sawRun = false
            loadPeople()
            step = .people
        case .idle, .failed: sawRun = false
        }
    }

    // MARK: - Step 4: who matters most

    /// Starts from the user's own `priorities.md` when it has entries (setup
    /// run again), else from the run's proposal.
    func loadPeople() {
        let existing = (try? String(contentsOf: TodayStore.prioritiesURL, encoding: .utf8)).map(TodayPriorities.parse) ?? []
        let found = (try? Data(contentsOf: TodayStore.folder.appendingPathComponent("candidates.json")))
            .flatMap(TodayCandidates.parse) ?? TodayCandidates()
        entries = existing.isEmpty ? found.proposal() : existing
        proposal = entries
        candidates = found.people.map(\.suggestion) + found.channels.map(\.suggestion)
        entryIndex = 0
        addText = ""
        removed = []
        loadContacts()
    }

    /// macOS Contacts join the suggestions only when Cai already has the
    /// grant. This never asks for it. Status picks whether to read, nothing
    /// else: a stale read only means fewer suggestions.
    private func loadContacts() {
        guard NativeAccessManager.liveState(for: .contacts) == .authorized else { return }
        Task.detached(priority: .utility) {
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
            var found: [TodaySuggestion] = []
            try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, stop in
                let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    found.append(TodaySuggestion(kind: .person, name: TodayPriorities.clean(name),
                                                 detail: contact.emailAddresses.first.map { $0.value as String }, from: "Contacts"))
                }
                if found.count >= 5000 { stop.pointee = true }
            }
            await MainActor.run { TodaySetup.shared.candidates += found }
        }
    }

    func select(_ index: Int) {
        if entries.indices.contains(index) { entryIndex = index }
    }

    func toggleStar(at index: Int) {
        guard entries.indices.contains(index), entries[index].kind == .person else { return }
        entryIndex = index
        entries[index].starred.toggle()
    }

    func remove(at index: Int) {
        guard entries.indices.contains(index) else { return }
        removed.append((entries[index], index))
        entries.remove(at: index)
        entryIndex = min(index, max(0, entries.count - 1))
        ToastQueue.post("Removed → ⌘Z to undo", outcome: .success)
    }

    private func undoRemove() {
        guard let last = removed.popLast() else { return }
        entries.insert(last.entry, at: min(last.index, entries.count))
        entryIndex = min(last.index, entries.count - 1)
        ToastQueue.post("Restored", outcome: .success)
    }

    /// ↵ with text: the picked suggestion, else the text as typed. People
    /// added by hand are starred: naming someone is the strongest signal.
    func add(_ picked: TodaySuggestion? = nil) {
        let pick = picked ?? suggestions[safe: suggestionIndex]
        let text = TodayPriorities.clean(addText)
        addText = ""
        suggestionIndex = 0
        let entry: TodayPriorityEntry
        if let pick {
            entry = TodayPriorityEntry(kind: pick.kind, name: pick.name, reason: "Added by you, from \(pick.from)", starred: pick.kind == .person)
        } else if !text.isEmpty {
            let kind: TodayPriorityEntry.Kind = text.hasPrefix("#") ? .channel : .person
            entry = TodayPriorityEntry(kind: kind, name: text, reason: "Added by you", starred: kind == .person)
        } else {
            return
        }
        let index = entry.kind == .person ? (entries.firstIndex { $0.kind == .channel } ?? entries.count) : entries.count
        entries.insert(entry, at: index)
        entryIndex = index
        ToastQueue.post("Added \(entry.name)", outcome: .success)
    }

    func showToday() {
        save()
        ToastQueue.post("Saved → your Today list is ready", outcome: .success)
    }

    /// Writes `priorities.md` (the user's file when there is one, else the
    /// template, with only the People and Slack channels lines replaced) and
    /// ends setup. The first list was built without it, so a changed list
    /// starts a refresh that ranks with it.
    private func save() {
        let url = TodayStore.prioritiesURL
        let base = (try? String(contentsOf: url, encoding: .utf8))
            ?? TodaySkill.bundledURL.flatMap { try? String(contentsOf: $0.appendingPathComponent("priorities.template.md"), encoding: .utf8) }
            ?? TodayPriorities.fallbackTemplate
        try? FileManager.default.createDirectory(at: TodayStore.stateFolder, withIntermediateDirectories: true)
        try? TodayPriorities.render(entries, into: base).write(to: url, atomically: true, encoding: .utf8)
        step = nil
        if entries != proposal { runner.start() }
    }

    private static func wrap(_ index: Int, _ count: Int) -> Int {
        ((index % count) + count) % count
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - View

struct TodaySetupView: View {
    @ObservedObject var setup: TodaySetup
    @ObservedObject private var runner = TodayRunner.shared
    let step: TodaySetup.Step
    let escLabel: String

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.caiDivider)
            content
            Spacer(minLength: 0)
            Divider().background(Color.caiDivider)
            footer
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .intro: intro
        case .skill: skillStep
        case .tools: toolsStep
        case .building: buildingStep
        case .people: peopleStep
        }
    }

    private var header: some View {
        let (title, subtitle): (String, String) = {
            switch step {
            case .intro: return ("Today", "Not set up")
            case .skill: return ("Set Up Today", "Step 1 of 3")
            case .tools: return ("Set Up Today", "Step 2 of 3")
            case .building: return ("Today", "Building your list")
            case .people: return ("Set Up Today", "Step 3 of 3")
            }
        }()
        return HStack(spacing: 10) {
            Image(systemName: "sun.max")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.caiPrimary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.caiTextPrimary)
                Text(subtitle).font(.system(size: 11)).foregroundColor(.caiTextSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Steps

    private var intro: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(["slack", "gmail", "github", "notion", "calendar"], id: \.self) { TodaySourceLogo(source: $0) }
            }
            Text("See what needs you today")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.caiTextPrimary)
            Text("Your Claude reads Slack, Gmail and your other tools and ranks what needs you.")
                .font(.system(size: 11))
                .foregroundColor(.caiTextSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("Set Up Today") { setup.enter() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.caiTextPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.caiSurface.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.caiDivider, lineWidth: 0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 30)
    }

    private var skillStep: some View {
        let line: String = {
            switch setup.skill {
            case .missing: return "It reads your tools and writes the list Cai shows here. Continue adds it to:"
            case .identical: return "Already added to Claude, here:"
            case .symlink: return "Already added, and managed elsewhere (this is a link). Cai leaves it as it is:"
            case .differs: return "A different cai-today skill is already here, maybe one you edited. Cai leaves it as it is and uses it:"
            }
        }()
        return VStack(alignment: .leading, spacing: 12) {
            stepTitle("Add the cai-today skill to Claude", line)
            Text("~/.claude/skills/cai-today/")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.caiTextPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.caiSurface.opacity(0.6)))
            if let error = setup.skillError {
                Text(error).font(.system(size: 11)).foregroundColor(.caiError)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var toolsStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch setup.tools {
            case .checking:
                stepTitle("Your tools", nil)
                HStack(spacing: 6) {
                    SetupPulse()
                    Text("Asking Claude which tools it can reach")
                }
                .font(.system(size: 11))
                .foregroundColor(.caiTextSecondary)
            case .failed(let reason):
                stepTitle("Your tools", nil)
                Text("\(reason). ⌘R checks again.").font(.system(size: 11)).foregroundColor(.caiError)
            case .ready(let rows):
                let ready = rows.filter { $0.status == .connected }.count
                stepTitle("Your tools", "\(ready) of \(rows.count) ready. Today reads only your DMs, mentions and threads.")
                ForEach(Array(rows.enumerated()), id: \.element.source) { index, row in
                    toolRow(row, index: index, selected: index == setup.toolIndex)
                }
                if setup.enabledCount == 0 {
                    Text("Turn on at least one tool to continue.")
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary)
                }
            }
        }
        .padding(16)
    }

    private func toolRow(_ row: TodaySetup.ToolRow, index: Int, selected: Bool) -> some View {
        HStack(spacing: 8) {
            TodaySourceLogo(source: row.source.rawValue).frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.source.title).font(.system(size: 12, weight: .medium)).foregroundColor(.caiTextPrimary)
                Text(row.status.subtitle(for: row.source))
                    .font(.system(size: 10))
                    .foregroundColor(.caiTextSecondary.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer()
            if row.status == .connected {
                Toggle("", isOn: Binding(get: { row.on }, set: { _ in setup.toggle(at: index) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(.caiPrimary)
                    .labelsHidden()
                    .accessibilityLabel(row.source.title)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.caiSurface.opacity(0.3)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.caiPrimary : Color.clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { setup.toggle(at: index) }
    }

    /// One row per source the run reads: Waiting until the run calls one of
    /// its tools, then Reading. The stream doesn't say when a source is
    /// finished, so no row claims it.
    private var buildingStep: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(setup.building, id: \.self) { source in
                buildRow(TodaySourceLogo(source: source.rawValue), source.title,
                         state: runner.reading.contains(source) ? "Reading" : "Waiting")
            }
            buildRow(Image(systemName: "person.2").foregroundColor(.caiTextSecondary), "Who you work with most",
                     state: runner.wroteCandidates ? "Done" : "Waiting")
            Group {
                if case .failed(let reason) = runner.phase {
                    Text("Couldn't build the list: \(reason).").foregroundColor(.caiError)
                } else {
                    Text("Building your list. Cai can close; it keeps going.").foregroundColor(.caiTextSecondary)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }

    private func buildRow<Logo: View>(_ logo: Logo, _ name: String, state: String) -> some View {
        HStack(spacing: 10) {
            logo.frame(width: 20, height: 20)
            Text(name).font(.system(size: 13, weight: .medium)).foregroundColor(.caiTextPrimary)
            Spacer()
            HStack(spacing: 5) {
                if state == "Reading" && runner.isRunning { SetupPulse() }
                Text(state)
            }
            .font(.system(size: 11))
            .foregroundColor(.caiTextSecondary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .accessibilityElement(children: .combine)
    }

    private var peopleStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepTitle("Who matters most", "Found in the last 30 days. Starred people rank first.")
            VStack(alignment: .leading, spacing: 2) {
                section("People", kind: .person)
                section("Slack channels", kind: .channel)
            }
            addField
            if !setup.addText.isEmpty { suggestionList }
            Text("Your DMs, mentions and threads are always read. Nothing here is required.")
                .font(.system(size: 11))
                .foregroundColor(.caiTextSecondary)
        }
        .padding(16)
    }

    @ViewBuilder
    private func section(_ title: String, kind: TodayPriorityEntry.Kind) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.caiTextSecondary)
            .padding(.horizontal, 12)
            .padding(.top, 6)
        ForEach(Array(setup.entries.enumerated()).filter { $0.element.kind == kind }, id: \.offset) { index, entry in
            entryRow(entry, index: index, selected: index == setup.entryIndex && setup.addText.isEmpty)
        }
    }

    private func entryRow(_ entry: TodayPriorityEntry, index: Int, selected: Bool) -> some View {
        HStack(spacing: 10) {
            if entry.kind == .person {
                Button { setup.toggleStar(at: index) } label: {
                    Image(systemName: entry.starred ? "star.fill" : "star")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(entry.starred ? .caiPrimary : .caiTextSecondary.opacity(0.6))
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
                .help(entry.starred ? "Unstar" : "Star")
                .accessibilityLabel(entry.starred ? "Unstar \(entry.name)" : "Star \(entry.name)")
            } else {
                Text("#").font(.system(size: 13, weight: .medium)).foregroundColor(.caiTextSecondary).frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.kind == .channel ? String(entry.name.drop { $0 == "#" }) : entry.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.caiTextPrimary)
                    .lineLimit(1)
                if !entry.reason.isEmpty {
                    Text(entry.reason).font(.system(size: 11)).foregroundColor(.caiTextSecondary).lineLimit(1)
                }
            }
            Spacer()
            Button { setup.remove(at: index) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.caiTextSecondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Remove")
            .accessibilityLabel("Remove \(entry.name)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.caiPrimarySubtle : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { setup.select(index) }
    }

    private var addField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.caiTextSecondary)
            Text(setup.addText.isEmpty ? "Type a name, email, @handle or #channel to add" : setup.addText)
                .font(.system(size: 13))
                .foregroundColor(setup.addText.isEmpty ? .caiTextSecondary.opacity(0.6) : .caiTextPrimary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.caiSurface.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(setup.addText.isEmpty ? Color.clear : Color.caiPrimary.opacity(0.5), lineWidth: 1))
    }

    private var suggestionList: some View {
        let suggestions = setup.suggestions
        return VStack(alignment: .leading, spacing: 0) {
            if suggestions.isEmpty {
                Text("No match. ↵ adds “\(setup.addText)” as typed.")
                    .font(.system(size: 11))
                    .foregroundColor(.caiTextSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                HStack(spacing: 8) {
                    if suggestion.kind == .channel {
                        Text("#").font(.system(size: 12, weight: .medium)).frame(width: 16)
                    } else {
                        Image(systemName: "person").font(.system(size: 11)).frame(width: 16)
                    }
                    Text(suggestion.kind == .channel ? String(suggestion.name.drop { $0 == "#" }) : suggestion.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.caiTextPrimary)
                    if let detail = suggestion.detail {
                        Text(detail).font(.system(size: 11)).foregroundColor(.caiTextSecondary).lineLimit(1)
                    }
                    Spacer()
                    Text(suggestion.from).font(.system(size: 10)).foregroundColor(.caiTextSecondary.opacity(0.7))
                }
                .foregroundColor(.caiTextSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(index == setup.suggestionIndex ? Color.caiPrimarySubtle : Color.clear))
                .contentShape(Rectangle())
                .onTapGesture { setup.add(suggestion) }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.caiSurface.opacity(0.3)))
    }

    private func stepTitle(_ title: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(.caiTextPrimary)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundColor(.caiTextSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Footer

    /// The step's own keys on the left; Back, then the default button, on the
    /// right (the macOS convention). The default button is ↵, so it needs no hint.
    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            switch step {
            case .intro:
                KeyboardHint(key: "↵", label: "Set up")
                Spacer(minLength: 0)
                KeyboardHint(key: "Esc", label: escLabel)
            case .skill:
                Spacer(minLength: 0)
                backButton { _ = setup.esc() }
                defaultButton("Continue", enabled: setup.skillError == nil) { setup.enter() }
            case .tools:
                if case .ready = setup.tools { KeyboardHint(key: "Space", label: "Turn on or off") }
                KeyboardHint(key: "⌘R", label: "Check again")
                Spacer(minLength: 0)
                backButton { _ = setup.esc() }
                defaultButton("Continue", enabled: setup.enabledCount > 0) { setup.enter() }
            case .building:
                if case .failed = runner.phase {
                    KeyboardHint(key: "Esc", label: escLabel)
                    Spacer(minLength: 0)
                    backButton { setup.backToTools() }
                    defaultButton("Try Again", enabled: true) { setup.enter() }
                } else {
                    Spacer(minLength: 0)
                    KeyboardHint(key: "Esc", label: "\(escLabel), keeps building")
                }
            case .people:
                if setup.addText.isEmpty {
                    KeyboardHint(key: "Esc", label: escLabel)
                    KeyboardHint(key: "Space", label: "Star")
                    KeyboardHint(key: "⌘⌫", label: "Remove")
                } else {
                    KeyboardHint(key: "↑↓", label: "Pick")
                    KeyboardHint(key: "↵", label: "Add")
                    KeyboardHint(key: "Esc", label: "Clear")
                }
                Spacer(minLength: 0)
                defaultButton("Show Today", enabled: setup.addText.isEmpty) { setup.showToday() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func backButton(_ action: @escaping () -> Void) -> some View {
        Button("Back", action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(.caiTextSecondary)
            .padding(.horizontal, 8)
    }

    private func defaultButton(_ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.caiPrimaryFill.opacity(enabled ? 1 : 0.4)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// The in-progress dot: a slow fade, never a spinner (DESIGN.md Motion).
private struct SetupPulse: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color.caiTextSecondary)
            .frame(width: 7, height: 7)
            .opacity(dim ? 0.45 : 1)
            .accessibilityAddTraits(.updatesFrequently)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}
