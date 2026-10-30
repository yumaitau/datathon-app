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
            banner(icon: "wifi.slash", tint: .orange.mix(with: .black, by: 0.4)) {
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
            banner(icon: "arrow.triangle.2.circlepath", tint: .teal.mix(with: .black, by: 0.4)) {
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
        .background(tint.gradient.opacity(0.95), ignoresSafeAreaEdges: .top)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Stacks the connectivity banner above a tab's navigation stack so it never covers the
    /// navigation bar and stays visible on pushed screens.
    func connectivityBanner(profileId: String?) -> some View {
        VStack(spacing: 0) {
            if let profileId { ConnectivityBanner(profileId: profileId) }
            self
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

/// Post image, loaded on the standard (non-satellite) session. Satellite mode never loads media.
struct PostMedia: View {
    let imageUrl: String?
    @Environment(NetworkMonitor.self) private var network
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if !network.isSatelliteMode, let url = resolvedURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    MediaPlaceholder()
                }
            }
            .accessibilityLabel(Text("Photo"))
        } else {
            MediaPlaceholder()
        }
    }

    private var resolvedURL: URL? {
        guard let imageUrl, !imageUrl.isEmpty else { return nil }
        if imageUrl.hasPrefix("http") { return URL(string: imageUrl) }
        return URL(string: settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + imageUrl)
    }
}

/// Neutral stand-in when no image is available or media is held back for coverage.
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
            .overlay { Text(initials).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(Color.accentColor) }
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

/// Resolves a catalog string for an explicit locale. UIKit-rendered chrome (navigation titles,
/// tab bar labels) ignores SwiftUI's `\.locale`, so the in-app language toggle resolves them here.
/// A downloaded community translation wins; otherwise the String Catalog (English fallback).
func localizedString(_ key: String, locale: Locale) -> String {
    if let translated = StringOverrides.shared.value(for: key) { return translated }
    var resource = LocalizedStringResource(String.LocalizationValue(key))
    resource.locale = locale
    return String(localized: resource)
}

private struct LocalizedNavigationTitle: ViewModifier {
    let key: String
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        content.navigationTitle(localizedString(key, locale: locale))
    }
}

extension View {
    func localizedNavigationTitle(_ key: String) -> some View {
        modifier(LocalizedNavigationTitle(key: key))
    }
}
