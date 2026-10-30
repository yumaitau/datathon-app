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

    init(target: CommentTarget, groupId: String, commentsEnabled: Bool, threadLocked: Bool) {
        self.target = target
        self.groupId = groupId
        self.commentsEnabled = commentsEnabled
        self.threadLocked = threadLocked
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
                    .foregroundStyle(.secondary)
            } else {
                if comments.isEmpty && pending.isEmpty {
                    Text(canLoad ? LocalizedStringKey("No comments yet.") : LocalizedStringKey("Comments will load when you have normal coverage."))
                        .foregroundStyle(.secondary)
                }
                ForEach(comments) { comment in
                    commentRow(comment, isReply: false)
                    ForEach(comment.replies ?? []) { reply in
                        commentRow(reply, isReply: true)
                    }
                }
                ForEach(pending) { m in
                    let body = m.payloadValue["body"] ?? ""
                    HStack(alignment: .top) {
                        if m.payloadValue["parentCommentId"] != nil { Spacer().frame(width: 24) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profiles.activeProfile?.name ?? "").font(.caption.weight(.semibold))
                            Text(body)
                            Label("Waiting to send", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .opacity(0.7)
                }
                if threadLocked {
                    Label("An Elder has locked this thread.", systemImage: "lock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    composer
                }
            }
            ErrorBanner(message: error)
        } header: {
            Text("Comments")
        }
        .task(id: target) { await load() }
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

    @ViewBuilder
    private func commentRow(_ c: Comment, isReply: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if isReply { Rectangle().fill(Color(.separator)).frame(width: 2).padding(.leading, 8).padding(.trailing, 10) }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(c.author.name).font(.caption.weight(.semibold))
                    Text(c.createdAt, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.secondary)
                }
                if c.status == "hidden" || c.status == "removed" {
                    Text("Comment hidden by an Elder").italic().foregroundStyle(.secondary)
                } else {
                    Text(c.body)
                    HStack(spacing: 10) {
                        ReactionBar(counts: counts(c), mine: mine(c), compact: true) { kind in
                            Task { await react(c, kind: kind) }
                        }
                        Spacer()
                        actionsMenu(c, isReply: isReply)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Reply (when the thread is open), report, and Elder hide.
    private func actionsMenu(_ c: Comment, isReply: Bool) -> some View {
        Menu {
            if commentsEnabled && !threadLocked {
                Button { replyTo = isReply ? topLevel(of: c) : c } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
            }
            Button { reporting = c } label: { Label("Report", systemImage: "flag") }
            if isElder {
                Button(role: .destructive) { Task { await hide(c) } } label: { Label("Hide comment", systemImage: "eye.slash") }
            }
        } label: {
            Image(systemName: "ellipsis").frame(minWidth: 32, minHeight: 32)
        }
        .accessibilityLabel(Text("Comment actions"))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let replyTo {
                HStack {
                    Text("Replying to \(replyTo.author.name)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { self.replyTo = nil }.font(.caption)
                }
            }
            HStack(alignment: .bottom) {
                TextField("Add a comment", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(Text("Send comment"))
            }
        }
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
