import SwiftData
import SwiftUI

/// Offline / satellite / syncing banner shown at the top of each tab.
struct ConnectivityBanner: View {
    @Environment(NetworkMonitor.self) private var network
    @Environment(SyncEngine.self) private var sync
    @Environment(ProfileStore.self) private var profiles
    @Query private var queued: [PendingMutation]

    init(profileId: String) {
        _queued = Query(filter: #Predicate<PendingMutation> { $0.profileId == profileId && $0.state == "queued" })
    }

    var body: some View {
        if network.isSatelliteMode {
            banner(icon: "antenna.radiowaves.left.and.right", tint: .indigo) {
                Text("Satellite mode: essentials only").font(.subheadline.weight(.semibold))
                if let d = sync.deferred, d.posts + d.events > 0 {
                    Text("\(d.posts + d.events) updates waiting for coverage").font(.caption)
                }
                if !queued.isEmpty {
                    Text("\(queued.count) changes waiting to send").font(.caption)
                }
            }
        } else if !network.isOnline {
            banner(icon: "wifi.slash", tint: .orange) {
                Text("You're offline").font(.subheadline.weight(.semibold))
                Group {
                    if queued.isEmpty {
                        Text("Showing saved information.")
                    } else {
                        Text("\(queued.count) changes will sync when you reconnect.")
                    }
                }
                .font(.caption)
            }
        } else if sync.isSyncing && !queued.isEmpty {
            banner(icon: "arrow.triangle.2.circlepath", tint: .teal) {
                Text("Syncing \(queued.count) changes…").font(.subheadline.weight(.semibold))
            }
        }
    }

    private func banner(icon: String, tint: Color, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) { content() }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tint.gradient)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Adds the connectivity banner above the content of a tab root.
    func connectivityBanner(profileId: String?) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if let profileId { ConnectivityBanner(profileId: profileId) }
        }
    }
}

struct Badge: View {
    let text: LocalizedStringKey
    var systemImage: String?
    var tint: Color = .accentColor

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let systemImage { Image(systemName: systemImage) }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.15), in: Capsule())
        .foregroundStyle(tint)
    }
}

/// Stand-in for post media (the API exposes `hasMedia` only). Satellite mode never loads media.
struct MediaPlaceholder: View {
    @Environment(NetworkMonitor.self) private var network

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(.secondarySystemBackground))
            .frame(height: 160)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: network.isSatelliteMode ? "icloud.slash" : "photo")
                        .font(.title2)
                    Text(network.isSatelliteMode ? LocalizedStringKey("Media waiting for coverage") : LocalizedStringKey("Photo"))
                        .font(.footnote)
                }
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
    }
}

struct ErrorBanner: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}

struct InitialsAvatar: View {
    let initials: String
    var size: CGFloat = 44

    var body: some View {
        Circle()
            .fill(Color.accentColor.opacity(0.18))
            .frame(width: size, height: size)
            .overlay { Text(initials).font(.headline).foregroundStyle(Color.accentColor) }
            .accessibilityHidden(true)
    }
}

enum Format {
    static func bytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

/// Normalises Australian mobile input ("0400 000 003", "61400…") to E.164.
func normalizePhone(_ raw: String) -> String {
    let digits = raw.filter { $0.isNumber || $0 == "+" }
    if digits.hasPrefix("+") { return digits }
    if digits.hasPrefix("61") { return "+" + digits }
    if digits.hasPrefix("0") { return "+61" + digits.dropFirst() }
    return digits.isEmpty ? "" : "+" + digits
}
