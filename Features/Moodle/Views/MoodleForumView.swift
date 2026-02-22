import SwiftUI

struct MoodleForumView: View {
    let discussion: MoodleDiscussion
    
    @State private var posts: [MoodlePost] = []
    @State private var isLoading = true
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text(discussion.subject)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.primary)
                    
                    HStack {
                        Text(discussion.userfullname)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Text(discussion.createdDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(Theme.Spacing.medium)
                
                Divider()

                // Always show the main discussion content first.
                Text(discussion.plainMessage.isEmpty ? "（無內文）" : discussion.plainMessage)
                    .font(.system(size: 15))
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
            let resp = try await MoodleService.shared.fetchDiscussionPosts(discussionId: discussion.id)
            // Some Moodle instances return the first post in both discussion + posts API.
            // Exclude it to avoid duplicated content in the detail view.
            posts = resp.posts
                .filter { $0.subject != discussion.subject || $0.plainMessage != discussion.plainMessage }
                .sorted { $0.timecreated < $1.timecreated }
        } catch {
            print("[Moodle] Discussion posts fallback: \(error)")
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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text(post.createdDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            Text(post.plainMessage)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
        .padding(Theme.Spacing.medium)
    }
}
