import SwiftUI

struct ToastView: View {
    let message: String
    
    var body: some View {
        Text(message)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.8))
            )
            .padding(.top, 50)
    }
}

#Preview {
    ToastView(message: "報名成功")
}
