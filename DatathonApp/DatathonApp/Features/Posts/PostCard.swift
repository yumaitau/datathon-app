import SwiftData
import SwiftUI

/// Feed-style post: author header, text, media, reaction summary and a react / comment bar.
/// In the feed the header and text open the post; on the post screen the full text shows and
/// "Comment" jumps to the comment box.
struct PostCard: View {
    let post: Post
    var isDetail = false
    var onComment: (() -> Void)?
    var onRemoved: (() -> Void)?

    @Environment(SyncEngine.self) private var sync
    @Environment(ProfileStore.self) private var profiles
    @State private var revealed = false

    private var mine: Set<String> { Set(post.myReactions ?? []) }
    private var counts: ReactionCounts { post.reactions ?? .zero }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if post.pinned {
                Label("Pinned", systemImage: "pin.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            ZStack(alignment: .topTrailing) {
                if isDetail {
                    mainContent
                } else {
                    NavigationLink(value: FeedRoute.post(post.id)) { mainContent.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .disabled(post.isSending)
                }
                if profiles.isElder(of: post.groupId) && !post.isSending {
                    PostElderMenu(post: post, onRemoved: onRemoved)
                        .padding(.trailing, 6)
                        .padding(.top, 6)
                }
            }
            if !post.isSending {
                summary
                Divider().padding(.horizontal, 16)
                actionBar
            }
        }
        .background(post.isSorryBusiness ? Color(.systemGray5) : Color(.secondarySystemGroupedBackground))
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            PostKindBadges(post: post)
            if let title = post.title, !title.isEmpty {
                Text(title).font(isDetail ? .title3.bold() : .headline)
            }
            if post.deceasedWarning && !revealed {
                if isDetail {
                    DeceasedWarningGate { revealed = true }
                } else {
                    Label("Cultural warning. Tap to view.", systemImage: "eye.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(post.body)
                    .font(.body)
                    .lineLimit(isDetail ? nil : 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Sorry business notices never show images.
                if (post.hasMedia == true || post.imageUrl != nil) && !post.isSorryBusiness {
                    PostMedia(imageUrl: post.imageUrl)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            InitialsAvatar(name: post.author.name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(post.author.name).font(.subheadline.weight(.semibold))
                HStack(spacing: 4) {
                    if post.isSending {
                        Label("Waiting to send", systemImage: "clock")
                    } else {
                        Text(post.createdAt, format: .relative(presentation: .named))
                    }
                    if post.restrictGender != nil || post.minAge != nil {
                        Text(verbatim: "·")
                        Image(systemName: "person.badge.shield.checkmark").accessibilityLabel(Text("Restricted"))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 36)
        }
    }

    @ViewBuilder
    private var summary: some View {
        let total = counts.total
        let comments = post.commentsEnabled ? post.commentCount ?? 0 : 0
        if total > 0 || comments > 0 {
            HStack(spacing: 6) {
                if total > 0 {
                    HStack(spacing: -4) {
                        ForEach(ReactionKind.allCases.filter { counts[$0] > 0 }, id: \.self) { kind in
                            kind.icon(active: true)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(kind.tint, in: Circle())
                                .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 1.5))
                        }
                    }
                    .accessibilityHidden(true)
                    Text("\(total)").monospacedDigit()
                }
                Spacer()
                if comments > 0 {
                    Text("^[\(comments) comment](inflect: true)")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .accessibilityElement(children: .combine)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 0) {
            reactButton
            if post.commentsEnabled {
                if isDetail {
                    Button { onComment?() } label: { barLabel("Comment", systemImage: "bubble.left") }
                        .disabled(post.threadLocked)
                } else {
                    NavigationLink(value: FeedRoute.post(post.id)) { barLabel("Comment", systemImage: "bubble.left") }
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }

    /// One tap gives the post's main reaction (Like, or Thinking of you for sorry business);
    /// touch and hold offers all reactions. A person keeps one reaction per post.
    private var reactButton: some View {
        let primary: ReactionKind = post.isSorryBusiness ? .thinkingOfYou : .like
        let current = ReactionKind.allCases.first { mine.contains($0.rawValue) }
        let shown = current ?? primary
        return Button { choose(current == nil ? primary : nil) } label: {
            shown.reactionLabel(active: current != nil)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(current == nil ? Color.secondary : shown.tint)
        }
        .contextMenu {
            ForEach(ReactionKind.allCases, id: \.self) { kind in
                Button { choose(current == kind ? nil : kind) } label: {
                    kind.reactionLabel(active: current == kind)
                }
            }
        }
        .accessibilityAddTraits(current != nil ? .isSelected : [])
        .accessibilityHint(Text("Touch and hold for more reactions"))
        .accessibilityActions {
            ForEach(ReactionKind.allCases, id: \.self) { kind in
                Button(kind.label) { choose(current == kind ? nil : kind) }
            }
        }
    }

    private func barLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
    }

    /// Switches this person's reaction to `kind` (or clears it) through the offline write queue.
    private func choose(_ kind: ReactionKind?) {
        for old in ReactionKind.allCases where mine.contains(old.rawValue) && old != kind {
            sync.enqueue(.reaction(targetType: "post", targetId: post.id, kind: old.rawValue))
        }
        if let kind, !mine.contains(kind.rawValue) {
            sync.enqueue(.reaction(targetType: "post", targetId: post.id, kind: kind.rawValue))
        }
    }
}

/// Elder moderation for one post: pin, comments, lock, deceased-person warning and remove.
/// Posts go up straight away, so this is how Elders look after the feed.
struct PostElderMenu: View {
    let post: Post
    var onRemoved: (() -> Void)?
    @Environment(AppEnvironment.self) private var env
    @Environment(NetworkMonitor.self) private var network
    @State private var confirmingRemove = false
    @State private var error: String?

    var body: some View {
        Menu {
            Button { update(\.pinned, to: !post.pinned) { try await env.api.post("/api/posts/\(post.id)/pin", ["pinned": $0]) } } label: {
                Label(post.pinned ? "Unpin" : "Pin to top", systemImage: post.pinned ? "pin.slash" : "pin")
            }
            Toggle("Comments on", isOn: binding(\.commentsEnabled, field: "commentsEnabled"))
            Toggle("Lock thread", isOn: binding(\.threadLocked, field: "threadLocked"))
            Toggle("Deceased-person warning", isOn: binding(\.deceasedWarning, field: "deceasedWarning"))
            Divider()
            Button(role: .destructive) { confirmingRemove = true } label: { Label("Remove post", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(!network.isOnline || network.isSatelliteMode)
        .accessibilityLabel(Text("Elder controls"))
        .confirmationDialog("Remove this post?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove post", role: .destructive) { Task { await remove() } }
        } message: {
            Text("It disappears for everyone in the group, including on phones that are offline once they sync.")
        }
        .alert("Couldn't update the post", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    private func binding(_ keyPath: WritableKeyPath<Post, Bool>, field: String) -> Binding<Bool> {
        Binding(get: { post[keyPath: keyPath] }, set: { value in
            update(keyPath, to: value) { try await env.api.post("/api/posts/\(post.id)/settings", [field: $0]) }
        })
    }

    /// Applies the change to the cache straight away and rolls it back if the server refuses.
    private func update(_ keyPath: WritableKeyPath<Post, Bool>, to value: Bool, send: @escaping (Bool) async throws -> OKResponse) {
        var updated = post
        updated[keyPath: keyPath] = value
        save(updated)
        Task {
            do { _ = try await send(value) }
            catch { self.error = error.localizedDescription; save(post) }
        }
    }

    private func save(_ p: Post) {
        guard let pid = env.profiles.activeProfileId else { return }
        env.cache.upsert(post: p, profileId: pid)
        try? env.container.mainContext.save()
    }

    private func remove() async {
        do {
            let _: OKResponse = try await env.api.post("/api/posts/\(post.id)/reject")
            if let pid = env.profiles.activeProfileId {
                env.cache.delete(profileId: pid, kind: CacheKind.post, id: post.id)
                try? env.container.mainContext.save()
            }
            onRemoved?()
        } catch { self.error = error.localizedDescription }
    }
}

extension InitialsAvatar {
    init(name: String, size: CGFloat = 44) {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        self.init(initials: initials, size: size)
    }
}

extension ReactionKind {
    var tint: Color {
        switch self {
        case .like: .blue
        case .heart: .pink
        case .thinkingOfYou: .purple
        case .deadly: .orange
        case .aboriginalFlag: .primary
        }
    }
}
