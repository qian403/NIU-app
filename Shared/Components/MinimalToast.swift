import SwiftUI

struct MinimalToast: View {
    let message: String
    let isSuccess: Bool
    
    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: isSuccess ? "checkmark.circle" : "exclamationmark.circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(isSuccess ? .black : .white)
            
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isSuccess ? .black : .white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 25)
                .fill(isSuccess ? Color.white : Color.black)
                .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 25)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
        )
    }
}

#Preview {
    VStack(spacing: 20) {
        MinimalToast(message: "操作成功", isSuccess: true)
        MinimalToast(message: "发生错误", isSuccess: false)
    }
    .padding()
}
