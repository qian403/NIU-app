import SwiftUI

struct MoodleForumView: View {
    let discussion: MoodleDiscussion
    private let repository: any MoodleDiscussionPostsRepositoryProtocol

    init(discussion: MoodleDiscussion, repository: (any MoodleDiscussionPostsRepositoryProtocol)? = nil) {
        self.discussion = discussion
        self.repository = repository ?? MoodleDiscussionPostsRepository()
    }
    
    @State private var posts: [MoodlePost] = []
    @State private var isLoading = true
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text(discussion.subject)
                        .font(.title3.weight(.bold))
                        .foregroundColor(.primary)
                    
                    HStack {
                        Text(discussion.userfullname)
                            .font(.footnote.weight(.medium))
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Text(MoodlePresentation.dateTime(discussion.createdDate))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(Theme.Spacing.medium)
                
                Divider()

                // Always show the main discussion content first.
                Text(discussion.plainMessage.isEmpty ? "（無內文）" : discussion.plainMessage)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .padding(Theme.Spacing.medium)
                
                if isLoading && posts.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding(.vertical, 20)
                        Spacer()
                    }
                } else if !posts.isEmpty {
                    Divider()
                    // Posts
                    ForEach(posts) { post in
                        PostView(post: post)
                        Divider()
                    }
                }
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("公告內容")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadPosts()
        }
    }
    
    private func loadPosts() async {
        do {
            let fetchedPosts = try await repository.fetchPosts(discussionId: discussion.id)
            try Task.checkCancellation()
            // Some Moodle instances return the first post in both discussion + posts API.
            // Exclude it to avoid duplicated content in the detail view.
            posts = fetchedPosts
                .filter { $0.subject != discussion.subject || $0.plainMessage != discussion.plainMessage }
                .sorted { $0.timecreated < $1.timecreated }
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
        }
        isLoading = false
    }
}

private struct PostView: View {
    let post: MoodlePost
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(post.author?.fullname ?? "未知")
                    .font(.footnote.weight(.medium))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text(MoodlePresentation.dateTime(post.createdDate))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Text(post.plainMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
        .padding(Theme.Spacing.medium)
    }
}
