import SwiftData
import SwiftUI

struct PostDetailView: View {
    let postId: String
    @Environment(AppEnvironment.self) private var env
    @Environment(ProfileStore.self) private var profiles
    @Environment(NetworkMonitor.self) private var network
    @Environment(SyncEngine.self) private var sync
    @Query private var items: [CachedItem]
    @State private var revealed = false
    @State private var error: String?

    init(postId: String) {
        self.postId = postId
        let key = CachedItem.key(profileId: AppEnvironment.shared.profiles.activeProfileId ?? "", kind: CacheKind.post, entityId: postId)
        _items = Query(filter: #Predicate<CachedItem> { $0.key == key })
    }

    var body: some View {
        if let post = items.first?.decode(Post.self) {
            content(post)
        } else {
            ContentUnavailableView("Post not available", systemImage: "doc.questionmark")
        }
    }

    private func content(_ post: Post) -> some View {
        let isElder = profiles.isElder(of: post.groupId)
        return List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    PostKindBadges(post: post)
                    if let title = post.title, !title.isEmpty {
                        Text(title).font(.title2.bold())
                    }
                    HStack {
                        Text(post.author.name).font(.subheadline.weight(.semibold))
                        Text(post.createdAt, format: .dateTime.day().month().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if post.deceasedWarning && !revealed {
                        DeceasedWarningGate { revealed = true }
                    } else {
                        Text(post.body).font(.body)
                        // Sorry business notices never show images.
                        if (post.hasMedia == true || post.imageUrl != nil) && !post.isSorryBusiness { PostMedia(imageUrl: post.imageUrl) }
                    }
                    if post.isPending {
                        Label("Waiting for Elder approval", systemImage: "hourglass").foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(post.isSorryBusiness ? Color(.systemGray6) : nil)

            if !post.isPending {
                Section {
                    ReactionBar(counts: post.reactions ?? .zero, mine: Set(post.myReactions ?? [])) { kind in
                        sync.enqueue(.reaction(targetType: "post", targetId: post.id, kind: kind.rawValue))
                    }
                }
            }

            if isElder && !post.id.hasPrefix("local-") {
                ElderPostControls(post: post, error: $error)
            }

            if !post.isPending {
                CommentsSection(target: .post(post.id), groupId: post.groupId,
                                commentsEnabled: post.commentsEnabled, threadLocked: post.threadLocked)
            }

            if let error { Section { ErrorBanner(message: error) } }
        }
        .localizedNavigationTitle(post.isSorryBusiness ? "Sorry business" : "Post")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DeceasedWarningGate: View {
    var onReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Cultural warning", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text("Aboriginal and Torres Strait Islander people are advised that this post may contain images, voices or names of people who have died.")
                .font(.subheadline)
            Button("View post", action: onReveal)
                .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ReactionBar: View {
    let counts: ReactionCounts
    let mine: Set<String>
    var compact = false
    var onToggle: (ReactionKind) -> Void

    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            ForEach(ReactionKind.allCases, id: \.self) { kind in
                let active = mine.contains(kind.rawValue)
                Button { onToggle(kind) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: kind.symbol(active: active))
                        if !compact || counts[kind] > 0 { Text("\(counts[kind])").monospacedDigit() }
                    }
                    .font(compact ? .caption : .subheadline)
                    .padding(.horizontal, compact ? 6 : 10)
                    .padding(.vertical, compact ? 3 : 6)
                    .background(active ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill), in: Capsule())
                    .foregroundStyle(active ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(kind.label))
                .accessibilityValue(Text("\(counts[kind])"))
                .accessibilityAddTraits(active ? .isSelected : [])
            }
            if !compact { Spacer() }
        }
    }
}

extension ReactionKind {
    func symbol(active: Bool) -> String {
        switch self {
        case .like: active ? "hand.thumbsup.fill" : "hand.thumbsup"
        case .heart: active ? "heart.fill" : "heart"
        case .thinkingOfYou: active ? "hands.and.sparkles.fill" : "hands.and.sparkles"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .like: "Like"
        case .heart: "Heart"
        case .thinkingOfYou: "Thinking of you"
        }
    }
}

/// Elder per-post settings: pin, comments on/off, lock thread, deceased-person warning.
private struct ElderPostControls: View {
    let post: Post
    @Binding var error: String?
    @Environment(AppEnvironment.self) private var env
    @Environment(NetworkMonitor.self) private var network

    var body: some View {
        Section {
            Toggle("Pinned", isOn: binding(\.pinned) { v in try await setPinned(v) })
            Toggle("Comments on", isOn: binding(\.commentsEnabled) { v in try await settings(["commentsEnabled": v]) })
            Toggle("Lock thread", isOn: binding(\.threadLocked) { v in try await settings(["threadLocked": v]) })
            Toggle("Deceased-person warning", isOn: binding(\.deceasedWarning) { v in try await settings(["deceasedWarning": v]) })
        } header: {
            Label("Elder controls", systemImage: "checkmark.shield")
        } footer: {
            if !network.isOnline || network.isSatelliteMode {
                Text("Elder controls need normal coverage.")
            }
        }
        .disabled(!network.isOnline || network.isSatelliteMode)
    }

    private func binding(_ keyPath: WritableKeyPath<Post, Bool>, action: @escaping (Bool) async throws -> Void) -> Binding<Bool> {
        Binding(
            get: { post[keyPath: keyPath] },
            set: { newValue in
                var updated = post
                updated[keyPath: keyPath] = newValue
                save(updated)
                Task {
                    do { try await action(newValue); error = nil }
                    catch { self.error = error.localizedDescription; save(post) }
                }
            })
    }

    private func save(_ p: Post) {
        guard let pid = env.profiles.activeProfileId else { return }
        env.cache.upsert(post: p, profileId: pid)
        try? env.container.mainContext.save()
    }

    private func setPinned(_ pinned: Bool) async throws {
        let _: OKResponse = try await env.api.post("/api/posts/\(post.id)/pin", ["pinned": pinned])
    }

    private func settings(_ body: [String: Bool]) async throws {
        let _: OKResponse = try await env.api.post("/api/posts/\(post.id)/settings", body)
    }
}
