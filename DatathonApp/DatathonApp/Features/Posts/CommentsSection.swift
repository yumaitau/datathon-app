import SwiftData
import SwiftUI

enum CommentTarget: Hashable {
    case post(String)
    case event(String)

    var id: String {
        switch self { case .post(let id), .event(let id): id }
    }
    var path: String {
        switch self {
        case .post(let id): "/api/posts/\(id)/comments"
        case .event(let id): "/api/events/\(id)/comments"
        }
    }
    var cacheId: String {
        switch self {
        case .post(let id): "post:\(id)"
        case .event(let id): "event:\(id)"
        }
    }
}

/// One-level comment thread with replies, reactions, reporting and Elder hide.
/// Comments are cached for offline reading; new comments go through the write queue.
struct CommentsSection: View {
    let target: CommentTarget
    let groupId: String
    let commentsEnabled: Bool
    let threadLocked: Bool
    /// Bump to move focus to the comment box (the post's "Comment" button).
    var focusTrigger = 0

    static let composerId = "comment-composer"

    @Environment(AppEnvironment.self) private var env
    @Environment(ProfileStore.self) private var profiles
    @Environment(NetworkMonitor.self) private var network
    @Environment(SyncEngine.self) private var sync
    @Query private var cached: [CachedItem]
    @Query private var pending: [PendingMutation]

    @State private var draft = ""
    @State private var replyTo: Comment?
    @State private var reporting: Comment?
    /// Reaction state changed on this screen since the thread was fetched, keyed by comment id;
    /// everything else comes from the server's counts on each comment.
    @State private var commentReactions: [String: ReactionCounts] = [:]
    @State private var myCommentReactions: [String: Set<String>] = [:]
    @State private var error: String?
    @State private var reportedNotice = false
    @FocusState private var composerFocused: Bool

    init(target: CommentTarget, groupId: String, commentsEnabled: Bool, threadLocked: Bool, focusTrigger: Int = 0) {
        self.target = target
        self.groupId = groupId
        self.commentsEnabled = commentsEnabled
        self.threadLocked = threadLocked
        self.focusTrigger = focusTrigger
        let pid = AppEnvironment.shared.profiles.activeProfileId ?? ""
        let key = CachedItem.key(profileId: pid, kind: CacheKind.comments, entityId: target.cacheId)
        let tid = target.id
        _cached = Query(filter: #Predicate<CachedItem> { $0.key == key })
        _pending = Query(filter: #Predicate<PendingMutation> {
            $0.profileId == pid && $0.type == "createComment" && $0.targetId == tid && $0.state == "queued"
        }, sort: \.createdAt)
    }

    private var comments: [Comment] { cached.first?.decode([Comment].self) ?? [] }
    private var isElder: Bool { profiles.isElder(of: groupId) }
    private var canLoad: Bool { network.isOnline && !network.isSatelliteMode }

    var body: some View {
        Section {
            if !commentsEnabled {
                Label("Comments are turned off for this post.", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            } else {
                if comments.isEmpty && pending.isEmpty {
                    Text(canLoad ? LocalizedStringKey("No comments yet. Start the conversation.") : LocalizedStringKey("Comments will load when you have normal coverage."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
                ForEach(comments) { comment in
                    commentRow(comment, isReply: false)
                    ForEach(comment.replies ?? []) { reply in
                        commentRow(reply, isReply: true)
                    }
                }
                ForEach(pending) { m in
                    pendingRow(body: m.payloadValue["body"] ?? "", isReply: m.payloadValue["parentCommentId"] != nil)
                }
                if threadLocked {
                    Label("An Elder has locked this thread.", systemImage: "lock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                } else {
                    composer
                        .id(Self.composerId)
                        .listRowSeparator(.hidden)
                }
            }
            ErrorBanner(message: error)
        } header: {
            Text("Comments")
        }
        .task(id: target) { await load() }
        .onChange(of: focusTrigger) { composerFocused = true }
        .confirmationDialog("Report this comment?", isPresented: Binding(get: { reporting != nil }, set: { if !$0 { reporting = nil } }), titleVisibility: .visible) {
            ForEach(["Disrespectful or hurtful", "Shares private information", "Cultural concern", "Something else"], id: \.self) { reason in
                Button(LocalizedStringKey(reason)) {
                    if let c = reporting { Task { await report(c, reason: reason) } }
                }
            }
        } message: {
            Text("An Elder will review it. The author isn't told who reported it.")
        }
        .alert("Thanks for letting us know", isPresented: $reportedNotice) {
            Button("OK") {}
        } message: {
            Text("An Elder will review this comment.")
        }
    }

    private func commentRow(_ c: Comment, isReply: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            InitialsAvatar(name: c.author.name, size: isReply ? 28 : 34)
            VStack(alignment: .leading, spacing: 4) {
                if c.status == "hidden" || c.status == "removed" {
                    Text("Comment hidden by an Elder")
                        .font(.subheadline)
                        .italic()
                        .foregroundStyle(.secondary)
                        .bubble()
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.author.name).font(.subheadline.weight(.semibold))
                        Text(c.body).font(.subheadline)
                    }
                    .bubble()
                    HStack(spacing: 16) {
                        Text(c.createdAt, format: .relative(presentation: .named))
                        likeButton(c)
                        if commentsEnabled && !threadLocked {
                            Button("Reply") {
                                replyTo = isReply ? topLevel(of: c) : c
                                composerFocused = true
                            }
                        }
                        Spacer(minLength: 0)
                        reactionSummary(counts(c))
                        actionsMenu(c)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .padding(.leading, 12)
                }
            }
        }
        .padding(.leading, isReply ? 42 : 0)
        .padding(.vertical, 2)
        .listRowSeparator(.hidden)
    }

    private func pendingRow(body: String, isReply: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            InitialsAvatar(name: profiles.activeProfile?.name ?? "", size: isReply ? 28 : 34)
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profiles.activeProfile?.name ?? "").font(.subheadline.weight(.semibold))
                    Text(body).font(.subheadline)
                }
                .bubble()
                Label("Waiting to send", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
            }
        }
        .padding(.leading, isReply ? 42 : 0)
        .opacity(0.7)
        .listRowSeparator(.hidden)
    }

    /// Tap to Like; touch and hold for Heart or Thinking of you. One reaction per person.
    private func likeButton(_ c: Comment) -> some View {
        let current = ReactionKind.allCases.first { mine(c).contains($0.rawValue) }
        return Button { Task { await choose(current == nil ? .like : nil, on: c) } } label: {
            Text(current?.label ?? "Like")
                .foregroundStyle(current?.tint ?? Color.secondary)
        }
        .contextMenu {
            ForEach(ReactionKind.allCases, id: \.self) { kind in
                Button { Task { await choose(current == kind ? nil : kind, on: c) } } label: {
                    Label(kind.label, systemImage: kind.symbol(active: current == kind))
                }
            }
        }
        .accessibilityAddTraits(current != nil ? .isSelected : [])
        .accessibilityActions {
            ForEach(ReactionKind.allCases, id: \.self) { kind in
                Button(kind.label) { Task { await choose(current == kind ? nil : kind, on: c) } }
            }
        }
    }

    @ViewBuilder
    private func reactionSummary(_ counts: ReactionCounts) -> some View {
        let total = counts.like + counts.heart + counts.thinkingOfYou
        if total > 0 {
            HStack(spacing: 2) {
                ForEach(ReactionKind.allCases.filter { counts[$0] > 0 }, id: \.self) { kind in
                    Image(systemName: kind.symbol(active: true)).foregroundStyle(kind.tint)
                }
                Text("\(total)").monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("^[\(total) reaction](inflect: true)"))
        }
    }

    /// Report, and Elder hide.
    private func actionsMenu(_ c: Comment) -> some View {
        Menu {
            Button { reporting = c } label: { Label("Report", systemImage: "flag") }
            if isElder {
                Button(role: .destructive) { Task { await hide(c) } } label: { Label("Hide comment", systemImage: "eye.slash") }
            }
        } label: {
            Image(systemName: "ellipsis").frame(minWidth: 32, minHeight: 32).contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Comment actions"))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let replyTo {
                HStack {
                    Text("Replying to \(replyTo.author.name)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { self.replyTo = nil }.font(.caption).buttonStyle(.plain)
                }
                .padding(.leading, 42)
            }
            HStack(alignment: .bottom, spacing: 8) {
                InitialsAvatar(name: profiles.activeProfile?.name ?? "", size: 34)
                TextField("Write a comment…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                Button {
                    send()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(Text("Send comment"))
            }
        }
        .padding(.vertical, 4)
    }

    private func counts(_ c: Comment) -> ReactionCounts { commentReactions[c.id] ?? c.reactions ?? .zero }
    private func mine(_ c: Comment) -> Set<String> { myCommentReactions[c.id] ?? Set(c.myReactions ?? []) }

    private func topLevel(of reply: Comment) -> Comment? {
        comments.first { $0.id == reply.parentCommentId } ?? reply
    }

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let mutation: QueuedMutation = switch target {
        case .post(let id): .createComment(postId: id, eventId: nil, parentCommentId: replyTo?.id, body: body)
        case .event(let id): .createComment(postId: nil, eventId: id, parentCommentId: replyTo?.id, body: body)
        }
        sync.enqueue(mutation, flushNow: false)
        draft = ""
        replyTo = nil
        Task {
            await sync.flush()
            await load()
        }
    }

    private func load() async {
        guard canLoad, let pid = profiles.activeProfileId else { return }
        do {
            let list: [Comment] = try await env.api.get(target.path)
            env.cache.upsert(list, profileId: pid, kind: CacheKind.comments, id: target.cacheId, sortDate: .now)
            try? env.container.mainContext.save()
            commentReactions = [:]
            myCommentReactions = [:]
            error = nil
        } catch let e as APIError where e.isOffline {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func react(_ c: Comment, kind: ReactionKind) async {
        if canLoad {
            struct Body: Encodable { let targetType: String; let targetId: String; let kind: String }
            do {
                let result: ReactionResult = try await env.api.post("/api/reactions", Body(targetType: "comment", targetId: c.id, kind: kind.rawValue))
                commentReactions[c.id] = result.counts
                var set = mine(c)
                if result.active { set.insert(kind.rawValue) } else { set.remove(kind.rawValue) }
                myCommentReactions[c.id] = set
                return
            } catch let e as APIError where !e.isOffline {
                error = e.localizedDescription
                return
            } catch {}
        }
        // Offline: queue the toggle and reflect it locally.
        sync.enqueue(.reaction(targetType: "comment", targetId: c.id, kind: kind.rawValue))
        var updated = counts(c)
        var set = mine(c)
        if set.remove(kind.rawValue) != nil { updated[kind] = max(0, updated[kind] - 1) }
        else { set.insert(kind.rawValue); updated[kind] += 1 }
        commentReactions[c.id] = updated
        myCommentReactions[c.id] = set
    }

    /// Switches this person's reaction on a comment to `kind`, or clears it.
    private func choose(_ kind: ReactionKind?, on c: Comment) async {
        for old in ReactionKind.allCases where mine(c).contains(old.rawValue) && old != kind {
            await react(c, kind: old)
        }
        if let kind, !mine(c).contains(kind.rawValue) { await react(c, kind: kind) }
    }

    private func report(_ c: Comment, reason: String) async {
        do {
            let _: OKResponse = try await env.api.post("/api/comments/\(c.id)/report", ["reason": reason])
            reportedNotice = true
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func hide(_ c: Comment) async {
        do {
            let _: OKResponse = try await env.api.post("/api/comments/\(c.id)/hide")
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

private extension View {
    /// Rounded grey speech bubble behind a comment.
    func bubble() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}
