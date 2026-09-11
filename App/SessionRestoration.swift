import Foundation
import ShhCore

public final class UserDefaultsSessionRestorationStore: SessionRestorationStore, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()

    public static let defaultStorageKey = "com.ervinpopescu.shh.session-restoration"

    public init(userDefaults: UserDefaults = .standard, storageKey: String = defaultStorageKey) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    public func save(_ metadata: SessionRestorationMetadata) async throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(metadata)
        lock.withLock {
            userDefaults.set(data, forKey: storageKey)
        }
    }

    public func load() async throws -> SessionRestorationMetadata? {
        lock.withLock {
            guard let data = userDefaults.data(forKey: storageKey) else {
                return nil
            }
            return try? JSONDecoder().decode(SessionRestorationMetadata.self, from: data)
        }
    }

    public func clear() async throws {
        lock.withLock {
            userDefaults.removeObject(forKey: storageKey)
        }
    }
}
