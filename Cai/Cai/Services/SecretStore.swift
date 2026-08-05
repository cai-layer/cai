import CaiActionCore
import Foundation
import Security

/// A secret's value, wrapped so it cannot be logged by accident.
///
/// `description` and `debugDescription` both return `<redacted>`, which covers
/// string interpolation, `print`, `String(describing:)`, `%@` formatting and
/// Sentry breadcrumbs built from any of those. Reaching the real characters
/// takes `.raw`, which is greppable in review. That turns CAI-07 from a rule
/// people have to remember into one the type enforces.
struct SecretValue: CustomStringConvertible, CustomDebugStringConvertible, Equatable, Sendable {
    let raw: String

    init(_ raw: String) {
        self.raw = raw
    }

    var description: String { "<redacted>" }
    var debugDescription: String { "<redacted>" }
}

/// What the Secrets list shows about a stored secret. Never its value.
struct SecretDescriptor: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let created: Date?
    let modified: Date?
}

/// Named secrets in the Keychain.
///
/// **The Keychain is the list.** `SecItemCopyMatching` with `kSecMatchLimitAll`
/// and `kSecReturnAttributes` enumerates the accounts under Cai's service with
/// their creation dates and without their values, so there is no registry in
/// UserDefaults to migrate, keep in sync, or leave orphaned when an item is
/// deleted from Keychain Access.
///
/// Same service and same posture as the model API keys in `KeychainHelper`: the
/// login keychain, no `kSecAttrSynchronizable` so nothing reaches iCloud, and no
/// per-item ACL, because an ACL prompt from a menu-bar app in the middle of an
/// Option+C action is worse than the flat posture. Hardening beyond that is a
/// migration covering every item, not this feature.
enum SecretStore {

    private static let service = Bundle.main.bundleIdentifier ?? "com.soyasis.cai"

    // MARK: - Reading

    /// Every stored secret, name and dates only, sorted by name.
    static func list() -> [SecretDescriptor] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false,
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { attributes -> SecretDescriptor? in
            guard let account = attributes[kSecAttrAccount as String] as? String,
                  let name = SecretReference.name(fromAccount: account) else {
                return nil  // the model API keys share this service
            }
            return SecretDescriptor(
                name: name,
                created: attributes[kSecAttrCreationDate as String] as? Date,
                modified: attributes[kSecAttrModificationDate as String] as? Date
            )
        }
        .sorted { $0.name < $1.name }
    }

    static func exists(_ name: String) -> Bool {
        list().contains { $0.name == name }
    }

    /// The value, for the moment of execution. Callers hold it no longer than
    /// the command that needs it.
    static func value(for name: String) -> SecretValue? {
        guard SecretReference.isValidName(name) else { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: SecretReference.accountName(for: name),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return SecretValue(string)
    }

    /// Resolves what a template asked for. Missing names come back in
    /// `missing` so the caller can name them rather than substituting nothing.
    static func resolve(_ names: Set<String>) -> (found: [String: SecretValue], missing: Set<String>) {
        var found: [String: SecretValue] = [:]
        var missing: Set<String> = []
        for name in names {
            if let value = value(for: name) {
                found[name] = value
            } else {
                missing.insert(name)
            }
        }
        return (found, missing)
    }

    // MARK: - Writing

    enum SaveResult: Equatable {
        case saved
        case replaced
        case invalidName(String)
        case keychainFailed(OSStatus)
    }

    /// Creates or overwrites. Overwriting is how a secret is rotated: forcing
    /// delete-then-create would break every action referencing the name in
    /// between, and buys nothing, since whoever can overwrite can also delete.
    @discardableResult
    static func save(_ value: String, name: String) -> SaveResult {
        if let rejection = SecretReference.nameRejection(name) {
            return .invalidName(rejection)
        }
        guard let data = value.data(using: .utf8) else {
            return .invalidName("That value cannot be stored as text.")
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: SecretReference.accountName(for: name),
        ]

        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return .replaced }
        guard update == errSecItemNotFound else { return .keychainFailed(update) }

        var item = query
        item[kSecValueData as String] = data
        let add = SecItemAdd(item as CFDictionary, nil)
        return add == errSecSuccess ? .saved : .keychainFailed(add)
    }

    // MARK: - Preparing a shell command

    /// Everything a shell call site needs to run a template that may reference
    /// secrets: what the engine is allowed to do, the environment the values
    /// travel in, and the values themselves for redacting output afterwards.
    struct ShellPreparation {
        /// nil when the template references no secret, which keeps templates
        /// without secrets on exactly the path they were on before.
        let access: TemplateEngine.SecretAccess?
        /// nil means "runner default". Non-nil carries `CAI_SECRET_*` on top of
        /// the usual shell environment.
        let environment: [String: String]?
        /// For `Redactor`, in case the command prints a value back.
        let values: [SecretValue]

        var isEmpty: Bool { access == nil }
    }

    /// One place all three shell call sites go through, so the environment
    /// cannot be wired into some of them and forgotten in the others.
    ///
    /// Throws `unknownSecret` rather than resolving a missing name to nothing: a
    /// command that runs with an empty credential fails somewhere far away, and
    /// the user reads the wrong error.
    static func prepareForShell(template: String) throws -> ShellPreparation {
        let referenced = SecretReference.names(in: template)
        guard !referenced.isEmpty else {
            return ShellPreparation(access: nil, environment: nil, values: [])
        }

        let (found, missing) = resolve(referenced)
        if let name = missing.sorted().first {
            throw TemplateEngine.FilterError.unknownSecret(name: name)
        }

        var environment = OutputDestinationService.shellEnvironment()
        for (name, secret) in found {
            environment[SecretReference.environmentVariable(for: name)] = secret.raw
        }

        return ShellPreparation(
            access: .environmentReference(found),
            environment: environment,
            values: Array(found.values)
        )
    }

    @discardableResult
    static func delete(_ name: String) -> Bool {
        guard SecretReference.isValidName(name) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: SecretReference.accountName(for: name),
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
