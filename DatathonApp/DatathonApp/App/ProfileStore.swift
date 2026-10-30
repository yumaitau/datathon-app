import Foundation
import Observation

/// A person signed in on this (possibly shared) device.
struct DeviceProfile: Codable, Hashable, Identifiable {
    var id: String // local id, scopes cache rows and Keychain items
    var userId: String
    var name: String
    var phoneNumber: String
    var needsSignIn: Bool = false

    var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// Multi-profile state. Tokens and PIN hashes live in the Keychain; the profile list and a cached
/// `Me` (group memberships only, no health data) live in UserDefaults.
@Observable
final class ProfileStore {
    private(set) var profiles: [DeviceProfile] = []
    private(set) var activeProfileId: String?
    private(set) var isLocked = true
    private(set) var me: Me?
    /// Incremented on every unlock so views can refresh when the same person unlocks again.
    private(set) var unlockCount = 0

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "profiles"),
           let list = try? JSONDecoder().decode([DeviceProfile].self, from: data) {
            profiles = list
        }
    }

    var activeProfile: DeviceProfile? { profiles.first { $0.id == activeProfileId } }
    var token: String? { activeProfileId.flatMap { Keychain.get("token.\($0)") } }
    var isUnlocked: Bool { activeProfile != nil && !isLocked }

    var currentUserRef: PersonRef? {
        activeProfile.map { PersonRef(id: $0.userId, name: $0.name) }
    }

    func isElder(of groupId: String) -> Bool { me?.isElderOf.contains(groupId) ?? false }

    // MARK: Profiles

    @discardableResult
    func addProfile(user: User, token: String, pin: String) -> DeviceProfile {
        if let existing = profiles.first(where: { $0.userId == user.id }) {
            Keychain.set(token, for: "token.\(existing.id)")
            setPIN(pin, for: existing.id)
            update(existing.id) { $0.needsSignIn = false; $0.name = user.name }
            unlock(existing.id)
            return existing
        }
        let profile = DeviceProfile(id: UUID().uuidString, userId: user.id, name: user.name, phoneNumber: user.phoneNumber)
        profiles.append(profile)
        Keychain.set(token, for: "token.\(profile.id)")
        setPIN(pin, for: profile.id)
        persist()
        unlock(profile.id)
        return profile
    }

    func reauthenticate(_ profileId: String, token: String, user: User) {
        Keychain.set(token, for: "token.\(profileId)")
        update(profileId) { $0.needsSignIn = false; $0.name = user.name }
    }

    func remove(_ profileId: String) {
        Keychain.delete("token.\(profileId)")
        Keychain.delete("pin.\(profileId)")
        defaults.removeObject(forKey: "me.\(profileId)")
        profiles.removeAll { $0.id == profileId }
        persist()
        if activeProfileId == profileId { activeProfileId = nil; me = nil; isLocked = true }
    }

    // MARK: PIN and lock

    func verifyPIN(_ pin: String, for profileId: String) -> Bool {
        Keychain.get("pin.\(profileId)") == Keychain.hashPIN(pin, salt: profileId)
    }

    func unlock(_ profileId: String) {
        activeProfileId = profileId
        me = cachedMe(profileId)
        isLocked = false
        unlockCount += 1
    }

    func lock() { isLocked = true }

    /// Called on 401: keep the profile but require OTP sign-in again after the PIN.
    func markNeedsSignIn() {
        guard let id = activeProfileId else { return }
        update(id) { $0.needsSignIn = true }
    }

    // MARK: Me

    func setMe(_ me: Me) {
        guard let id = activeProfileId else { return }
        self.me = me
        if let data = try? JSONEncoder.api.encode(me) { defaults.set(data, forKey: "me.\(id)") }
        if me.user.name != activeProfile?.name { update(id) { $0.name = me.user.name } }
    }

    func updateMemberships(_ memberships: [Membership]) {
        guard var me else { return }
        me.memberships = memberships
        setMe(me)
    }

    private func cachedMe(_ profileId: String) -> Me? {
        defaults.data(forKey: "me.\(profileId)").flatMap { try? JSONDecoder.api.decode(Me.self, from: $0) }
    }

    private func setPIN(_ pin: String, for profileId: String) {
        Keychain.set(Keychain.hashPIN(pin, salt: profileId), for: "pin.\(profileId)")
    }

    private func update(_ id: String, _ change: (inout DeviceProfile) -> Void) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        change(&profiles[i])
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(profiles), forKey: "profiles")
    }
}
