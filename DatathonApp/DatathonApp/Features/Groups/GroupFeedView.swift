import SwiftData
import SwiftUI

enum FeedRoute: Hashable {
    case post(String)
    case event(String)
    case moderation(groupId: String, groupName: String)
    case aunty(groupId: String, groupName: String)
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
            .filter { $0.status == "published" }
        // Pinned posts lead; everything else is newest first (the query's sort order).
        let feed = posts.filter(\.pinned) + posts.filter { !$0.pinned }
        let events = items.filter { $0.kind == CacheKind.event }.compactMap { $0.decode(Event.self) }
            .filter { !$0.cancelled && ($0.endsAt ?? $0.startsAt) > .now.addingTimeInterval(-6 * 3600) }
            .sorted { $0.startsAt < $1.startsAt }

        ScrollView {
            LazyVStack(spacing: 8) {
                if let error {
                    ErrorBanner(message: error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
                composerPrompt
                if !events.isEmpty { eventsStrip(events) }
                if feed.isEmpty {
                    ContentUnavailableView("No posts yet", systemImage: "text.bubble",
                                           description: Text("Be the first to share something with the community."))
                        .padding(.vertical, 32)
                }
                ForEach(feed) { PostCard(post: $0) }
            }
            .padding(.bottom, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(membership.groupName)
        .navigationDestination(for: FeedRoute.self) { route in
            switch route {
            case .post(let id): PostDetailView(postId: id)
            case .event(let id): EventDetailView(eventId: id)
            case let .moderation(gid, name): ModerationView(groupId: gid, groupName: name)
            case let .aunty(gid, name): AuntyChatView(groupId: gid, groupName: name)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: FeedRoute.aunty(groupId: membership.groupId, groupName: membership.groupName)) {
                    Label("Yarn with Aunty", systemImage: "bubble.left.and.text.bubble.right")
                }
            }
            if isElder {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(value: FeedRoute.moderation(groupId: membership.groupId, groupName: membership.groupName)) {
                        Label("Elder review", systemImage: "checkmark.shield")
                    }
                }
            }
        }
        .sheet(isPresented: $composing) {
            NavigationStack { ComposerView(groupId: membership.groupId, isElder: isElder) }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    /// "What's on your mind?" box that opens the composer.
    private var composerPrompt: some View {
        Button { composing = true } label: {
            HStack(spacing: 10) {
                InitialsAvatar(name: profiles.activeProfile?.name ?? "", size: 40)
                Text("What's on your mind?")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .padding(.horizontal, 14)
                    .overlay(Capsule().stroke(Color(.separator)))
                Image(systemName: "square.and.pencil")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color(.secondarySystemGroupedBackground))
        .accessibilityLabel(Text("New post"))
    }

    private func eventsStrip(_ events: [Event]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Upcoming events").font(.headline).padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(events) { e in
                        NavigationLink(value: FeedRoute.event(e.id)) { EventCard(event: e) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
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

struct PostKindBadges: View {
    let post: Post
    var body: some View {
        if post.isSorryBusiness || post.urgent == true || post.restrictGender != nil || post.minAge != nil {
            HStack(spacing: 6) {
                if post.isSorryBusiness {
                    Badge(text: "Sorry business", tint: .gray)
                } else if post.urgent == true {
                    Badge(text: "Urgent", systemImage: "exclamationmark.circle", tint: .red)
                }
                if let gender = post.restrictGender {
                    Badge(text: gender == "female" ? "Women only" : gender == "male" ? "Men only" : "Restricted",
                          systemImage: "person.badge.shield.checkmark", tint: .purple)
                }
                if let age = post.minAge {
                    Badge(text: "\(age)+ only", tint: .purple)
                }
            }
        }
    }
}

/// Event tile for the feed's horizontal "Upcoming events" strip.
struct EventCard: View {
    let event: Event
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(spacing: 0) {
                    Text(event.startsAt, format: .dateTime.month(.abbreviated)).font(.caption2.weight(.bold)).textCase(.uppercase)
                    Text(event.startsAt, format: .dateTime.day()).font(.title3.bold())
                }
                .frame(width: 44, height: 44)
                .foregroundStyle(Color.accentColor)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                Spacer()
                if let rsvp = event.myRsvp { RSVPBadge(response: rsvp) }
            }
            Text(event.title).font(.subheadline.weight(.semibold)).lineLimit(2, reservesSpace: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.startsAt, format: .dateTime.weekday(.wide).hour().minute())
                Text(event.location).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 210, alignment: .leading)
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
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
    @Environment(ProfileStore.self) private var profiles
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.dismiss) private var dismiss
    @FocusState private var bodyFocused: Bool
    @State private var kind = "general"
    @State private var title = ""
    @State private var text = ""
    @State private var urgent = false
    @State private var deceasedWarning = false
    @State private var audience = "everyone"
    @State private var adultsOnly = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    InitialsAvatar(name: profiles.activeProfile?.name ?? "", size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profiles.activeProfile?.name ?? "").font(.subheadline.weight(.semibold))
                        Menu {
                            Picker("Who can see this", selection: $audience) {
                                Label("Everyone", systemImage: "person.3").tag("everyone")
                                Label("Women only", systemImage: "figure.stand.dress").tag("female")
                                Label("Men only", systemImage: "figure.stand").tag("male")
                            }
                        } label: {
                            Label(audienceLabel, systemImage: audience == "everyone" ? "person.3" : "person.badge.shield.checkmark")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(.tertiarySystemFill), in: Capsule())
                        }
                        .accessibilityLabel(Text("Who can see this"))
                    }
                }
                TextField("Title (optional)", text: $title)
                    .font(.headline)
                TextField("What's on your mind?", text: $text, axis: .vertical)
                    .lineLimit(5...14)
                    .focused($bodyFocused)
            }

            Section {
                Picker("Type", selection: $kind) {
                    Text("General").tag("general")
                    Text("Announcement").tag("announcement")
                    if isElder { Text("Sorry business").tag("sorry_business") }
                }
                Toggle("Adults only (18+)", isOn: $adultsOnly)
            } footer: {
                if kind == "sorry_business" {
                    Text("Sorry business notices are text only, with comments off by default.")
                } else {
                    Text("Your post goes up straight away. Elders can remove posts that aren't right for the community.")
                }
            }

            if isElder {
                Section("Elder options") {
                    Toggle("Urgent notice", isOn: $urgent)
                    Toggle("Deceased-person warning", isOn: $deceasedWarning)
                }
            }

            if let error { Section { ErrorBanner(message: error) } }
        }
        .localizedNavigationTitle("Create post")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { bodyFocused = true }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Post") { Task { await submit() } }
                    .fontWeight(.semibold)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            }
        }
    }

    private var audienceLabel: LocalizedStringKey {
        switch audience {
        case "female": "Women only"
        case "male": "Men only"
        default: "Everyone"
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

        // Online: post directly so Elder-only flags apply and the post appears with its real id.
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
                dismiss()
                return
            } catch let e as APIError where e.isOffline {
                // fall through to the offline queue
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        // Offline: the post shows in the feed as "Waiting to send" until the queue flushes.
        env.sync.enqueue(.createPost(groupId: groupId, body: body, title: trimmedTitle.isEmpty ? nil : trimmedTitle, kind: kind, options: options))
        dismiss()
    }
}
