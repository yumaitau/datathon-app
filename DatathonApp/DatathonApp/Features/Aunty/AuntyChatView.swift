import SwiftUI

/// A private yarn with the AI Aunty.
///
/// Unlike the feed, nothing here is cached or queued. A yarn only makes sense
/// with a reply coming back, so offline and satellite both say so plainly
/// rather than silently banking the question for later. Nothing on this screen
/// is readable by Elders or anyone else — see the server's lib/aunty.ts.
struct AuntyChatView: View {
    let groupId: String
    let groupName: String

    @Environment(AppEnvironment.self) private var env
    @Environment(NetworkMonitor.self) private var network

    @State private var messages: [AuntyMessage] = []
    @State private var draft = ""
    @State private var loading = true
    @State private var sending = false
    @State private var unavailable: String?
    @State private var error: String?
    @State private var confirmingClear = false
    @FocusState private var composerFocused: Bool

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sending && network.isOnline && !network.isSatelliteMode && unavailable == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let unavailable {
                ContentUnavailableView("No Aunty here yet", systemImage: "person.crop.circle.badge.questionmark",
                                       description: Text(unavailable))
                    .frame(maxHeight: .infinity)
            } else {
                transcript
                Divider()
                composer
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Aunty")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !messages.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) { confirmingClear = true } label: {
                        Label("Clear this yarn", systemImage: "trash")
                    }
                }
            }
        }
        .confirmationDialog("Clear this yarn?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear it", role: .destructive) { Task { await clear() } }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Everything you and Aunty said is deleted. This can't be undone.")
        }
        .task { await load() }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    disclaimer
                    if loading && messages.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
                    } else if messages.isEmpty {
                        opener
                    }
                    ForEach(messages) { AuntyBubble(message: $0) }
                    if sending { typingIndicator }
                    if let error { ErrorBanner(message: error).padding(.horizontal, 16) }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.vertical, 16)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
            .onChange(of: sending) { _, _ in
                withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
        }
    }

    private let bottomAnchor = "aunty-bottom"

    /// Stated up front, every time. The Aunty is not an Elder and must not be
    /// mistaken for one.
    private var disclaimer: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Aunty is a computer helper the Elders of \(groupName) switched on. She's not a real Elder, and she won't share cultural knowledge or health advice. Your yarn is private — Elders can't read it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }

    private var opener: some View {
        AuntyBubble(message: AuntyMessage(
            id: "opener", author: "aunty",
            body: "Hello bub. What's going on for you today?",
            handoff: nil, mocked: false, createdAt: .now))
    }

    private var typingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Aunty's thinking…").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Composer

    @ViewBuilder
    private var composer: some View {
        if network.isSatelliteMode {
            composerNotice("antenna.radiowaves.left.and.right",
                           "Aunty needs proper coverage. She's not available on satellite.")
        } else if !network.isOnline {
            composerNotice("wifi.slash", "Aunty needs coverage to yarn back. Try again when you're online.")
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Tell Aunty what's going on…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                    .disabled(sending)
                Button { Task { await send() } } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                .disabled(!canSend)
                .accessibilityLabel(Text("Send to Aunty"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))
        }
    }

    private func composerNotice(_ icon: String, _ text: LocalizedStringKey) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(.systemBackground))
            .accessibilityElement(children: .combine)
    }

    // MARK: - Networking

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let thread: AuntyThread = try await env.api.get("/api/groups/\(groupId)/aunty")
            messages = thread.messages
            unavailable = nil
        } catch APIError.forbidden(let message) {
            unavailable = message.isEmpty ? String(localized: "The Elders haven't switched on an Aunty here.") : message
        } catch {
            // Offline on open is not an error worth a red banner; the composer says it.
            let mapped = APIClient.map(error)
            if !mapped.isOffline { self.error = mapped.localizedDescription }
        }
    }

    private func send() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        draft = ""
        error = nil
        sending = true
        defer { sending = false }

        struct Body: Encodable { let body: String; let clientMutationId: String }
        do {
            let reply: AuntyReply = try await env.api.post(
                "/api/groups/\(groupId)/aunty",
                Body(body: body, clientMutationId: UUID().uuidString))
            messages.append(contentsOf: reply.messages)
        } catch {
            // Put the words back in the box so nothing is lost.
            draft = body
            self.error = APIClient.map(error).localizedDescription
        }
    }

    private func clear() async {
        do {
            let _: OKResponse = try await env.api.delete("/api/groups/\(groupId)/aunty")
            messages = []
        } catch {
            self.error = APIClient.map(error).localizedDescription
        }
    }
}

/// One message. Aunty sits left in a plain card, the member sits right in the
/// accent colour, and a handover turns the card into a "go and see someone"
/// panel so it reads differently from ordinary chat.
struct AuntyBubble: View {
    let message: AuntyMessage

    var body: some View {
        HStack {
            if message.isAunty {
                content
                Spacer(minLength: 48)
            } else {
                Spacer(minLength: 48)
                content
            }
        }
        .padding(.horizontal, 16)
    }

    private var content: some View {
        // The handover panel stays its own accessibility element: combining the
        // whole bubble would hide "ring 13YARN" from VoiceOver.
        VStack(alignment: .leading, spacing: 8) {
            Text(message.body)
                .foregroundStyle(message.isAunty ? Color.primary : Color.white)
                .accessibilityLabel(Text(message.isAunty ? "Aunty said" : "You said"))
                .accessibilityValue(Text(message.body))
            if let handoff = message.handoffKind { HandoffNote(kind: handoff) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            message.isAunty ? AnyShapeStyle(Color(.secondarySystemGroupedBackground)) : AnyShapeStyle(Color.accentColor),
            in: RoundedRectangle(cornerRadius: 18))
    }
}

/// The "this one's for a real person" panel under a handover reply.
struct HandoffNote: View {
    let kind: AuntyHandoff

    private var icon: String {
        switch kind {
        case .health: "cross.case"
        case .sorryBusiness: "heart"
        case .crisis: "phone.arrow.up.right"
        case .elder: "person.2"
        }
    }

    private var text: LocalizedStringKey {
        switch kind {
        case .health: "This one's for the clinic, not for Aunty."
        case .sorryBusiness: "Sit with your people on this one."
        case .crisis: "Please ring someone. 13YARN 13 92 76 · Lifeline 13 11 14 · Emergency 000."
        case .elder: "This one belongs with your Elders."
        }
    }

    var body: some View {
        Label(text, systemImage: icon)
            .font(.footnote.weight(.medium))
            .foregroundStyle(kind == .crisis ? Color.red : Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (kind == .crisis ? Color.red : Color.accentColor).opacity(0.12),
                in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
    }
}
