import Foundation
import LocalAuthentication
import Security

enum GitHubTokenStore {
    private static let service = "com.olerida.AIusage.github"
    private static let account = "github-app"

    static func load(allowAuthenticationUI: Bool = false) throws -> GitHubCredentials? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        disableAuthenticationUIIfNeeded(in: &query, allowAuthenticationUI: allowAuthenticationUI)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw GitHubTokenStoreError.keychain(status)
        }
        return try JSONDecoder.github.decode(GitHubCredentials.self, from: data)
    }

    static func save(_ credentials: GitHubCredentials, allowAuthenticationUI: Bool = false) throws {
        let data = try JSONEncoder.github.encode(credentials)
        let itemIdentity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var lookup = itemIdentity
        disableAuthenticationUIIfNeeded(in: &lookup, allowAuthenticationUI: allowAuthenticationUI)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = itemIdentity
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw GitHubTokenStoreError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw GitHubTokenStoreError.keychain(status)
        }
    }

    static func delete(allowAuthenticationUI: Bool = false) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        disableAuthenticationUIIfNeeded(in: &query, allowAuthenticationUI: allowAuthenticationUI)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GitHubTokenStoreError.keychain(status)
        }
    }

    private static func disableAuthenticationUIIfNeeded(
        in query: inout [String: Any],
        allowAuthenticationUI: Bool
    ) {
        guard !allowAuthenticationUI else { return }
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
    }
}

struct GitHubCredentialMemoryCache {
    private enum State {
        case unloaded
        case loaded(GitHubCredentials?)
        case failed(any Error)
    }

    private var state: State = .unloaded

    mutating func load(
        using loader: () throws -> GitHubCredentials? = { try GitHubTokenStore.load() }
    ) throws -> GitHubCredentials? {
        switch state {
        case .loaded(let credentials):
            return credentials
        case .failed(let error):
            throw error
        case .unloaded:
            do {
                let credentials = try loader()
                state = .loaded(credentials)
                return credentials
            } catch {
                state = .failed(error)
                throw error
            }
        }
    }

    mutating func store(_ credentials: GitHubCredentials) {
        state = .loaded(credentials)
    }

    mutating func clear() {
        state = .loaded(nil)
    }
}

enum GitHubTokenStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
            return L10n.string("error.githubKeychain", detail)
        }
    }
}

extension JSONEncoder {
    static var github: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var github: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
