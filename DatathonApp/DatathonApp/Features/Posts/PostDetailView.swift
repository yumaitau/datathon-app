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
        case .deadly: active ? "flame.fill" : "flame"
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
        } else {
            Image(systemName: symbol(active: active))
        }
    }

    func reactionLabel(active: Bool) -> some View {
        Label { Text(label) } icon: { icon(active: active) }
    }
}
