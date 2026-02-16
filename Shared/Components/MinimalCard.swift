import SwiftUI

struct MinimalCard: View {
    let icon: String
    let title: String
    let subtitle: String
    var onTap: (() -> Void)?
    
    var body: some View {
        Button(action: {
            onTap?()
        }) {
            HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(.black)
                    .frame(width: 50, height: 50)
                    .background(
                        Circle()
                            .strokeBorder(Color.black.opacity(0.2), lineWidth: 1)
                    )
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.black)
                    
                    Text(subtitle)
                        .font(.system(size: 13, weight: .light))
                        .foregroundColor(.black.opacity(0.5))
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .light))
                    .foregroundColor(.black.opacity(0.3))
            }
            .padding(Theme.Spacing.medium)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                    .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    VStack(spacing: 16) {
        MinimalCard(
            icon: "house",
            title: "首页",
            subtitle: "返回主画面"
        )
        
        MinimalCard(
            icon: "gear",
            title: "设置",
            subtitle: "偏好设置与账户"
        )
    }
    .padding()
}
