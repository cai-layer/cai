import CaiActionCore
import Foundation

/// Reads the user's login-shell environment once, on demand, for the
/// "Import from shell…" flow in Settings → Secrets.
///
/// GUI apps inherit nothing from the terminal, and `zsh -c` sources only
/// `~/.zshenv`, so the tokens people actually export (in `.zshrc`,
/// `.bash_profile`, fish config) are invisible to Cai without this. The
/// capture is the VS Code pattern: spawn the user's own login shell
/// interactively, print the environment, parse, discard.
///
/// ```
/// getpwuid(getuid()).pw_shell ─▶ ShellRunner.run(executable: shell, flags: "-ilc",
///         │ (never $SHELL env —        "printf '\0CAI_ENV\0'; /usr/bin/env -0")
///         │  GUI apps don't have it)          │ 10s timeout
///         │ exec fails ─▶ retry /bin/zsh      ▼
///         └───────────────────▶ split stdout on the marker, parse NUL-separated
///                               KEY=VALUE after it (rc noise prints before it)
///                                       ─▶ filter ─▶ [Candidate]
/// ```
///
/// Everything this captures is secret material: parsed, filtered, handed to
/// `SecretStore.save` for the names the user ticks, and never logged or
/// retained past the import sheet.
enum ShellEnvCapture {

    /// Printed by the shell before `env -0` so rc noise (motd, echoes from
    /// `.zshrc`) can be discarded without guessing. NUL cannot appear in rc
    /// noise by accident: it terminates C strings, so shells don't emit it.
    static let marker = "\u{0}CAI_ENV\u{0}"

    /// One importable environment variable. The value is carried for the save
    /// and never displayed; `replacesExisting` drives the row's orange tag.
    struct Candidate: Equatable {
        let name: String
        let value: SecretValue
        let replacesExisting: Bool
        /// Token-shaped names (`*_TOKEN`, `*_KEY`, `*_SECRET`, `*API*`) sort
        /// before the rest, which collapse under "Show all".
        let looksLikeToken: Bool
    }

    /// Env-var names that pass the secret-name shape but are never
    /// credentials. Excluded outright rather than down-ranked: offering PATH
    /// as an importable secret erodes trust in the whole list.
    static let noise: Set<String> = [
        "PATH", "HOME", "SHELL", "USER", "LOGNAME", "TMPDIR", "PWD", "OLDPWD",
        "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID",
        "LANG", "LC_ALL", "LC_CTYPE", "EDITOR", "VISUAL", "PAGER", "MANPATH",
        "DISPLAY", "COLORTERM", "SHLVL", "HOSTNAME", "INFOPATH",
        "XPC_FLAGS", "XPC_SERVICE_NAME", "SSH_AUTH_SOCK", "HOMEBREW_PREFIX",
        "HOMEBREW_CELLAR", "HOMEBREW_REPOSITORY", "ZDOTDIR", "OSTYPE",
    ]

    private static let tokenMarkers = ["TOKEN", "KEY", "SECRET", "API", "PASSWORD", "CREDENTIAL"]

    /// The user's login shell from the user record. The `SHELL` environment
    /// variable is the wrong source here: launchd-spawned GUI apps don't
    /// reliably carry it.
    static func loginShell() -> String {
        if let passwd = getpwuid(getuid()), let shell = passwd.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }

    /// Runs the capture. Returns candidates, or throws the error whose
    /// message the import sheet's failure state shows.
    ///
    /// `-ilc` is interactive + login so both `.zshrc`-style (interactive) and
    /// `.zprofile`/`.bash_profile`-style (login) exports are sourced; fish
    /// accepts the same flags. A shell that rejects the flags or is missing
    /// falls back to plain zsh — worse coverage, never a dead end.
    static func capture() async throws -> [Candidate] {
        let command = "printf '\\0CAI_ENV\\0'; /usr/bin/env -0"
        let existing = Set(SecretStore.list().map(\.name))

        var output: ShellRunner.Output
        do {
            output = try await ShellRunner.run(
                command, stdin: "", timeout: captureTimeout,
                executable: loginShell(), flags: "-ilc"
            )
        } catch {
            // Exotic or missing login shell (csh rejects -ilc, chsh to a
            // deleted binary): retry with the shell every Mac has.
            output = try await ShellRunner.run(
                command, stdin: "", timeout: captureTimeout,
                executable: "/bin/zsh", flags: "-ilc"
            )
        }
        if output.timedOut {
            throw CaptureError.timedOut
        }
        guard output.status == 0 else {
            throw CaptureError.shellFailed(status: output.status)
        }
        guard output.stdout.contains(marker) else {
            // The shell ran but our command never printed: an rc file that
            // exec's something else, or output swallowed. An error, not an
            // empty candidate list — "no variables found" would be a lie.
            throw CaptureError.markerMissing
        }
        return candidates(fromCaptureOutput: output.stdout, existing: existing)
    }

    static let captureTimeout: TimeInterval = 10

    enum CaptureError: LocalizedError, Equatable {
        case timedOut
        case shellFailed(status: Int32)
        case markerMissing

        var errorDescription: String? {
            switch self {
            case .timedOut:
                return "Your shell took more than \(Int(ShellEnvCapture.captureTimeout)) seconds to start."
            case .shellFailed(let status):
                return "Your shell exited with code \(status) before printing its environment."
            case .markerMissing:
                return "Your shell's output couldn't be read."
            }
        }
    }

    /// Pure parse + filter, table-tested without a subprocess.
    ///
    /// Everything before the marker is rc noise and dropped. After it, entries
    /// are NUL-separated `KEY=VALUE`; `-0` is what lets multiline values
    /// survive. Entries without `=`, names that fail the secret shape, and the
    /// noise list are skipped. Token-shaped names sort first, then
    /// alphabetically within each group.
    static func candidates(fromCaptureOutput output: String, existing: Set<String>) -> [Candidate] {
        guard let markerRange = output.range(of: marker) else { return [] }
        let payload = output[markerRange.upperBound...]

        var found: [Candidate] = []
        var seen: Set<String> = []
        for entry in payload.split(separator: "\u{0}", omittingEmptySubsequences: true) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let name = String(entry[..<equals])
            let value = String(entry[entry.index(after: equals)...])

            guard SecretReference.isValidName(name),
                  !noise.contains(name),
                  !name.hasPrefix(SecretReference.environmentPrefix),
                  !seen.contains(name) else { continue }
            seen.insert(name)

            found.append(Candidate(
                name: name,
                value: SecretValue(value),
                replacesExisting: existing.contains(name),
                looksLikeToken: tokenMarkers.contains { name.contains($0) }
            ))
        }

        return found.sorted {
            if $0.looksLikeToken != $1.looksLikeToken { return $0.looksLikeToken }
            return $0.name < $1.name
        }
    }
}
