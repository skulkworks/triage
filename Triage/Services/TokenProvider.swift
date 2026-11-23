import Foundation
import Security

/// Where the GitHub token comes from: a token saved in the Keychain, or the GitHub CLI's login.
nonisolated enum TokenSource: String, Sendable {
    case keychain, githubCLI
}

nonisolated enum TokenProvider {
    private static let service = Bundle.main.bundleIdentifier ?? "dev.skulkworks.triage"
    private static let account = "github-token"

    static func resolve() async -> (token: String, source: TokenSource)? {
        if let saved = load() { return (saved, .keychain) }
        if let cli = await ghCLIToken() { return (cli, .githubCLI) }
        return nil
    }

    // MARK: Keychain

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func save(_ token: String) {
        delete()
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Triage token",
            kSecValueData as String: Data(token.utf8),
        ]
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: GitHub CLI

    /// Apps started from Finder don't get the shell's PATH, so look where gh usually lives.
    static func ghPath() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh",
                          NSHomeDirectory() + "/.local/bin/gh", "/run/current-system/sw/bin/gh"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func ghCLIToken() async -> String? {
        guard let gh = ghPath() else { return nil }
        return await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: gh)
            p.arguments = ["auth", "token", "--hostname", "github.com"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            p.terminationHandler = { proc in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: proc.terminationStatus == 0 && !token.isEmpty ? token : nil)
            }
            do { try p.run() } catch { cont.resume(returning: nil) }
        }
    }
}
