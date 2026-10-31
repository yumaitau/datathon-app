import SwiftData
import SwiftUI

struct PostDetailView: View {
    let postId: String
    @Environment(\.dismiss) private var dismiss
    @Query private var items: [CachedItem]
    @State private var focusComposer = 0

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
        ScrollViewReader { proxy in
            List {
                PostCard(post: post, isDetail: true,
                         onComment: {
                             withAnimation { proxy.scrollTo(CommentsSection.composerId, anchor: .bottom) }
                             focusComposer += 1
                         },
                         onRemoved: { dismiss() })
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)

                CommentsSection(target: .post(post.id), groupId: post.groupId,
                                commentsEnabled: post.commentsEnabled, threadLocked: post.threadLocked,
                                focusTrigger: focusComposer)
            }
            .listStyle(.plain)
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

extension ReactionKind {
    func symbol(active: Bool) -> String {
        switch self {
        case .like: active ? "hand.thumbsup.fill" : "hand.thumbsup"
        case .heart: active ? "heart.fill" : "heart"
        case .thinkingOfYou: active ? "hands.and.sparkles.fill" : "hands.and.sparkles"
        case .deadly: "arrow.up.right"
        case .aboriginalFlag: "flag.fill"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .like: "Like"
        case .heart: "Heart"
        case .thinkingOfYou: "Thinking of you"
        case .deadly: "Deadly"
        case .aboriginalFlag: "Aboriginal flag"
        }
    }

    @ViewBuilder
    func icon(active: Bool) -> some View {
        if self == .aboriginalFlag {
            // Australian Aboriginal flag: equal black/red halves, central yellow disc.
            ZStack {
                VStack(spacing: 0) {
                    Color.black
                    Color(red: 0.89, green: 0, blue: 0.17)
                }
                Circle().fill(Color(red: 1, green: 0.84, blue: 0))
                    .frame(width: 7, height: 7)
            }
            .frame(width: 21, height: 14)
            .accessibilityHidden(true)
        } else if self == .deadly {
            SpearIcon().fill(.primary)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        } else {
            Image(systemName: symbol(active: active))
        }
    }

    func reactionLabel(active: Bool) -> some View {
        Label { Text(label) } icon: { icon(active: active) }
    }
}

/// A plain spear silhouette, without decorative cultural motifs.
private struct SpearIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points: [CGPoint] = [
            .init(x: 0.10, y: 0.90), .init(x: 0.66, y: 0.34),
            .init(x: 0.57, y: 0.25), .init(x: 0.94, y: 0.06),
            .init(x: 0.75, y: 0.43), .init(x: 0.66, y: 0.34),
            .init(x: 0.16, y: 0.96),
        ]
        path.addLines(points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) })
        path.closeSubpath()
        return path
    }
}

/// Shared anchored reaction tray for posts and comments.
struct ReactionPickerButton<Content: View>: View {
    let current: ReactionKind?
    let primary: ReactionKind
    var choose: (ReactionKind?) -> Void
    @ViewBuilder var content: () -> Content
    @State private var showingPicker = false

    var body: some View {
        Button { choose(current == nil ? primary : nil) } label: { content() }
            .highPriorityGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in showingPicker = true })
            .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(ReactionKind.allCases, id: \.self) { kind in
                            Button {
                                choose(current == kind ? nil : kind)
                                showingPicker = false
                            } label: {
                                kind.icon(active: true)
                                    .font(.title2)
                                    .foregroundStyle(kind.tint)
                                    .frame(width: 48, height: 48)
                                    .background(current == kind ? Color.accentColor.opacity(0.15) : .clear, in: Circle())
                                    .overlay {
                                        if current == kind { Circle().stroke(Color.accentColor, lineWidth: 2) }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(kind.label))
                            .accessibilityIdentifier("reaction-option-\(kind.rawValue)")
                            .accessibilityAddTraits(current == kind ? .isSelected : [])
                            .help(Text(kind.label))
                        }
                    }
                    .padding(12)
                }
                .scrollIndicators(.hidden)
                .frame(width: 280, height: 72)
                .presentationCompactAdaptation(.popover)
            }
            .accessibilityAddTraits(current != nil ? .isSelected : [])
            .accessibilityHint(Text("Touch and hold for more reactions"))
            .accessibilityAction(named: Text("Choose reaction")) { showingPicker = true }
            .accessibilityActions {
                ForEach(ReactionKind.allCases, id: \.self) { kind in
                    Button(kind.label) { choose(current == kind ? nil : kind) }
                }
            }
    }
}
