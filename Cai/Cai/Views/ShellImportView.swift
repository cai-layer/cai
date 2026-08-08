import CaiActionCore
import SwiftUI

/// Import from shell — three states inline in the list area: working,
/// candidates, failure. Values are never rendered in any state, not even
/// masked; the checkbox rows show names only.
struct ShellImportView: View {
    /// Called with how many secrets were saved (0 = nothing imported).
    let onDone: (Int) -> Void
    let onCancel: () -> Void
    let onAddManually: () -> Void

    private enum Phase {
        case working
        case candidates([ShellEnvCapture.Candidate])
        case failed(String)
        /// Some saves failed: names that made it, names that did not.
        case partial(saved: Int, failures: [(name: String, status: OSStatus)])
    }
    @State private var phase: Phase = .working
    @State private var ticked: Set<String> = []
    @State private var showAll = false
    @State private var pulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            privacyLine

            switch phase {
            case .working:
                working
            case .candidates(let candidates):
                if candidates.isEmpty {
                    emptyCapture
                } else {
                    candidateList(candidates)
                    footer(candidates)
                }
            case .failed(let why):
                failure(why)
            case .partial(let saved, let failures):
                partial(saved: saved, failures: failures)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await capture() }
    }

    private var privacyLine: some View {
        Text("Cai runs your login shell once to read its environment. Values go straight to the Keychain and are never shown.")
            .font(.system(size: 11))
            .foregroundColor(.caiTextSecondary.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Working

    private var working: some View {
        HStack(spacing: 8) {
            Text("◉")
                .font(.system(size: 12))
                .foregroundColor(.caiTextSecondary)
                .opacity(pulsing ? 1.0 : 0.45)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = true }
                .accessibilityAddTraits(.updatesFrequently)
            Text("Reading your shell environment…")
                .font(.system(size: 12))
                .foregroundColor(.caiTextSecondary)
        }
        .padding(.top, 8)
    }

    private func capture() async {
        do {
            let found = try await ShellEnvCapture.capture()
            // Preselect nothing: importing a credential is an explicit act.
            withAnimation(.easeOut(duration: 0.2)) { phase = .candidates(found) }
        } catch {
            withAnimation(.easeOut(duration: 0.2)) {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Candidates

    @ViewBuilder
    private func candidateList(_ candidates: [ShellEnvCapture.Candidate]) -> some View {
        let tokenish = candidates.filter(\.looksLikeToken)
        let rest = candidates.filter { !$0.looksLikeToken }

        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(tokenish, id: \.name) { candidateRow($0) }

                if !rest.isEmpty {
                    if showAll {
                        ForEach(rest, id: \.name) { candidateRow($0) }
                    } else {
                        Button(action: { withAnimation(.easeOut(duration: 0.15)) { showAll = true } }) {
                            Text("Show all (\(rest.count))")
                                .font(.system(size: 11))
                                .foregroundColor(.caiTextSecondary)
                                .underline()
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
            }
        }
        .frame(maxHeight: 240)
    }

    private func candidateRow(_ candidate: ShellEnvCapture.Candidate) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { ticked.contains(candidate.name) },
                set: { on in
                    if on { ticked.insert(candidate.name) } else { ticked.remove(candidate.name) }
                }
            )) {
                Text(candidate.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.caiTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(candidate.name)
            }
            .toggleStyle(.checkbox)

            if candidate.replacesExisting {
                Text("replaces existing")
                    .font(.system(size: 11))
                    .foregroundColor(.caiError)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func footer(_ candidates: [ShellEnvCapture.Candidate]) -> some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.caiTextSecondary)

            Button(action: { importTicked(from: candidates) }) {
                Text("Import \(ticked.count) Secret\(ticked.count == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.caiPrimary.opacity(ticked.isEmpty ? 0.4 : 1))
                    )
            }
            .buttonStyle(.plain)
            .disabled(ticked.isEmpty)
        }
    }

    private func importTicked(from candidates: [ShellEnvCapture.Candidate]) {
        var saved = 0
        var failures: [(String, OSStatus)] = []
        for candidate in candidates where ticked.contains(candidate.name) {
            switch SecretStore.save(candidate.value.raw, name: candidate.name) {
            case .saved, .replaced:
                saved += 1
            case .invalidName:
                // Cannot happen: candidates passed isValidName. Counted as a
                // failure rather than dropped silently, just in case.
                failures.append((candidate.name, errSecParam))
            case .keychainFailed(let status):
                failures.append((candidate.name, status))
            }
        }
        // Republish here, not only on the way out: a partial failure parks on
        // the .partial screen without calling onDone, and if the user abandons
        // it (focus loss, quit) the secrets that DID save would otherwise stay
        // invisible to the agent until the next relaunch.
        if saved > 0 { ActionsSnapshotPublisher.shared.publishNow() }
        if failures.isEmpty {
            onDone(saved)
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                phase = .partial(saved: saved, failures: failures)
            }
        }
    }

    // MARK: - Empty / failure / partial

    private var emptyCapture: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No token-shaped variables found in your shell.")
                .font(.system(size: 12))
                .foregroundColor(.caiTextPrimary)
            addManuallyButton
        }
        .padding(.top, 8)
    }

    private func failure(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.caiError)
                Text("Couldn't read your shell environment.")
                    .font(.system(size: 12))
                    .foregroundColor(.caiTextPrimary)
            }
            Text(why)
                .font(.system(size: 11))
                .foregroundColor(.caiTextSecondary.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            addManuallyButton
        }
        .padding(.top, 8)
    }

    private func partial(saved: Int, failures: [(name: String, status: OSStatus)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if saved > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.caiSuccess)
                    Text("\(saved) secret\(saved == 1 ? "" : "s") saved in Keychain")
                        .font(.system(size: 12))
                        .foregroundColor(.caiTextPrimary)
                        .monospacedDigit()
                }
            }
            ForEach(failures, id: \.name) { failure in
                Text("\(failure.name) couldn't be saved (Keychain error \(failure.status)).")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.caiError)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Done") { onDone(saved) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.caiTextSecondary)
            }
        }
        .padding(.top, 8)
    }

    private var addManuallyButton: some View {
        Button(action: onAddManually) {
            Text("Add manually instead")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.caiTextSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.caiSurface.opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.caiDivider.opacity(0.5), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}
