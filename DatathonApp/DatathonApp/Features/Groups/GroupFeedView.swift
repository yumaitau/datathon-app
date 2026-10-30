import SwiftData
import SwiftUI

enum FeedRoute: Hashable {
    case post(String)
    case event(String)
    case moderation(groupId: String, groupName: String)
}

struct GroupFeedView: View {
    let membership: Membership
    @Environment(AppEnvironment.self) private var env
    @Environment(ProfileStore.self) private var profiles
    @Environment(NetworkMonitor.self) private var network
    @Query private var items: [CachedItem]
    @State private var composing = false
    @State private var error: String?

    init(membership: Membership) {
        self.membership = membership
        let pid = AppEnvironment.shared.profiles.activeProfileId ?? ""
        let gid = membership.groupId
        _items = Query(filter: #Predicate<CachedItem> { $0.profileId == pid && $0.groupId == gid },
                       sort: \.sortDate, order: .reverse)
    }

    private var isElder: Bool { profiles.isElder(of: membership.groupId) }

    var body: some View {
        let posts = items.filter { $0.kind == CacheKind.post }.compactMap { $0.decode(Post.self) }
        let pinned = posts.filter { $0.pinned && !$0.isPending }
        let mine = posts.filter { $0.isPending }
        let others = posts.filter { !$0.pinned && !$0.isPending && $0.status == "published" }
        let events = items.filter { $0.kind == CacheKind.event }.compactMap { $0.decode(Event.self) }
            .filter { !$0.cancelled && ($0.endsAt ?? $0.startsAt) > .now.addingTimeInterval(-6 * 3600) }
            .sorted { $0.startsAt < $1.startsAt }

        List {
            if let error { Section { ErrorBanner(message: error) } }

            if !pinned.isEmpty {
                Section {
                    ForEach(pinned) { PostLink(post: $0) }
                } header: {
                    Label("Pinned", systemImage: "pin.fill")
                }
            }

            if !mine.isEmpty {
                Section("Waiting for Elder approval") {
                    ForEach(mine) { PostLink(post: $0) }
                }
            }

            if !events.isEmpty {
                Section("Upcoming events") {
                    ForEach(events) { e in
                        NavigationLink(value: FeedRoute.event(e.id)) { EventRow(event: e) }
                    }
                }
            }

            Section("Announcements") {
                if others.isEmpty {
                    Text("No announcements yet.").foregroundStyle(.secondary)
                }
                ForEach(others) { PostLink(post: $0) }
            }
        }
        .navigationTitle(membership.groupName)
        .navigationDestination(for: FeedRoute.self) { route in
            switch route {
            case .post(let id): PostDetailView(postId: id)
            case .event(let id): EventDetailView(eventId: id)
            case let .moderation(gid, name): ModerationView(groupId: gid, groupName: name)
            }
        }
        .toolbar {
            if isElder {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(value: FeedRoute.moderation(groupId: membership.groupId, groupName: membership.groupName)) {
                        Label("Elder review", systemImage: "checkmark.shield")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { composing = true } label: { Label("New post", systemImage: "square.and.pencil") }
            }
        }
        .sheet(isPresented: $composing) {
            NavigationStack { ComposerView(groupId: membership.groupId, isElder: isElder) }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let pid = profiles.activeProfileId else { return }
        // Satellite mode: feed comes from the cache only; no extra requests.
        guard network.isOnline, !network.isSatelliteMode else { return }
        do {
            let feed: FeedResponse = try await env.api.get("/api/groups/\(membership.groupId)/feed")
            env.cache.replaceFeed(feed, groupId: membership.groupId, profileId: pid)
            try? env.container.mainContext.save()
            error = nil
        } catch let e as APIError where e.isOffline {
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct PostLink: View {
    let post: Post
    var body: some View {
        NavigationLink(value: FeedRoute.post(post.id)) { PostRow(post: post) }
            .disabled(post.id.hasPrefix("local-"))
    }
}

struct PostRow: View {
    let post: Post
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PostKindBadges(post: post)
                Spacer()
                Text(post.createdAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let title = post.title, !title.isEmpty {
                Text(title).font(.headline)
            }
            if post.deceasedWarning {
                Label("Cultural warning. Tap to view.", systemImage: "eye.slash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(post.body).font(.subheadline).lineLimit(4)
            }
            HStack(spacing: 12) {
                Text(post.author.name)
                if post.isPending {
                    Label("Waiting for Elder approval", systemImage: "hourglass")
                        .foregroundStyle(.orange)
                } else {
                    if let c = post.commentCount, c > 0, post.commentsEnabled {
                        Label("\(c)", systemImage: "bubble.left")
                    }
                    if let r = post.reactions, r.like + r.heart + r.thinkingOfYou > 0 {
                        Label("\(r.like + r.heart + r.thinkingOfYou)", systemImage: "heart")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .listRowBackground(post.isSorryBusiness ? Color(.systemGray6) : nil)
    }
}

struct PostKindBadges: View {
    let post: Post
    var body: some View {
        HStack(spacing: 6) {
            if post.isSorryBusiness {
                Badge(text: "Sorry business", tint: .gray)
            } else if post.urgent == true {
                Badge(text: "Urgent", systemImage: "exclamationmark.circle", tint: .red)
            }
            if post.pinned { Badge(text: "Pinned", systemImage: "pin.fill") }
            if post.restrictGender != nil || post.minAge != nil {
                Badge(text: "Restricted", systemImage: "person.badge.shield.checkmark", tint: .purple)
            }
        }
    }
}

struct EventRow: View {
    let event: Event
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack {
                Text(event.startsAt, format: .dateTime.month(.abbreviated)).font(.caption.weight(.semibold)).textCase(.uppercase)
                Text(event.startsAt, format: .dateTime.day()).font(.title2.bold())
            }
            .frame(minWidth: 44)
            .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title).font(.headline)
                Text(event.startsAt, format: .dateTime.weekday(.wide).hour().minute()).font(.subheadline)
                Text(event.location).font(.caption).foregroundStyle(.secondary)
                if let rsvp = event.myRsvp {
                    RSVPBadge(response: rsvp)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct RSVPBadge: View {
    let response: String
    var body: some View {
        switch response {
        case "going": Badge(text: "Going", systemImage: "checkmark", tint: .green)
        case "maybe": Badge(text: "Maybe", systemImage: "questionmark", tint: .orange)
        default: Badge(text: "Not going", systemImage: "xmark", tint: .gray)
        }
    }
}

struct ComposerView: View {
    let groupId: String
    let isElder: Bool
    @Environment(AppEnvironment.self) private var env
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "announcement"
    @State private var title = ""
    @State private var text = ""
    @State private var urgent = false
    @State private var deceasedWarning = false
    @State private var audience = "everyone"
    @State private var adultsOnly = false
    @State private var busy = false
    @State private var error: String?
    @State private var resultMessage: LocalizedStringKey?

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $kind) {
                    Text("Announcement").tag("announcement")
                    Text("General").tag("general")
                    if isElder { Text("Sorry business").tag("sorry_business") }
                }
                TextField("Title (optional)", text: $title)
                TextField("What would you like to share?", text: $text, axis: .vertical)
                    .lineLimit(4...12)
            } footer: {
                if isElder {
                    Text("As an Elder, your posts publish straight away.")
                } else {
                    Text("An Elder reviews posts before they appear in the community.")
                }
            }

            Section {
                Picker("Who can see this", selection: $audience) {
                    Text("Everyone").tag("everyone")
                    Text("Women only").tag("female")
                    Text("Men only").tag("male")
                }
                Toggle("Adults only (18+)", isOn: $adultsOnly)
            } footer: {
                Text("For women's and men's business, and content not suitable for young people.")
            }

            if isElder {
                Section("Elder options") {
                    Toggle("Urgent notice", isOn: $urgent)
                    Toggle("Deceased-person warning", isOn: $deceasedWarning)
                }
            }

            if kind == "sorry_business" {
                Section {
                    Text("Sorry business notices are text only, with comments off by default.")
                        .font(.footnote)
                }
            }

            if let error { Section { ErrorBanner(message: error) } }
        }
        .localizedNavigationTitle("New post")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isElder ? LocalizedStringKey("Publish") : LocalizedStringKey("Submit")) { Task { await submit() } }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            }
        }
        .alert("Post submitted", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil; dismiss() } })) {
            Button("OK") {}
        } message: {
            if let resultMessage { Text(resultMessage) }
        }
    }

    private var options: PostOptions {
        PostOptions(urgent: isElder && urgent,
                    deceasedWarning: isElder && deceasedWarning,
                    restrictGender: audience == "everyone" ? nil : audience,
                    minAge: adultsOnly ? 18 : nil)
    }

    private func submit() async {
        busy = true; error = nil
        defer { busy = false }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let cmid = UUID().uuidString
        guard let pid = env.profiles.activeProfileId else { return }

        // Online: post directly so Elder-only flags apply and we get the real status back.
        if network.isOnline && !network.isSatelliteMode {
            struct Body: Encodable {
                let body: String; let title: String?; let kind: String; let clientMutationId: String
                let urgent: Bool?; let deceasedWarning: Bool?; let restrictGender: String?; let minAge: Int?
            }
            let o = options
            do {
                let post: Post = try await env.api.post("/api/groups/\(groupId)/posts", Body(
                    body: body, title: trimmedTitle.isEmpty ? nil : trimmedTitle, kind: kind, clientMutationId: cmid,
                    urgent: isElder ? o.urgent : nil, deceasedWarning: isElder ? o.deceasedWarning : nil,
                    restrictGender: o.restrictGender, minAge: o.minAge))
                env.cache.upsert(post: post, profileId: pid)
                try? env.container.mainContext.save()
                resultMessage = post.isPending ? "Waiting for Elder approval. It will appear once an Elder approves it." : "Your post is live."
                return
            } catch let e as APIError where e.isOffline {
                // fall through to the offline queue
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        env.sync.enqueue(.createPost(groupId: groupId, body: body, title: trimmedTitle.isEmpty ? nil : trimmedTitle, kind: kind, options: options))
        resultMessage = "Saved on this phone. It will be sent for Elder approval when you're back in coverage."
    }
}
