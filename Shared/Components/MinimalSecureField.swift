import SwiftUI

struct MinimalSecureField: View {
    @Binding var text: String
    let placeholder: String
    @Binding var isVisible: Bool
    let icon: String
    
    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .light))
                .foregroundColor(.primary)
                .frame(width: 24)
            
            Group {
                if isVisible {
                    TextField("", text: $text, prompt: Text(placeholder).foregroundColor(.black.opacity(0.5)))
                } else {
                    SecureField("", text: $text, prompt: Text(placeholder).foregroundColor(.black.opacity(0.5)))
                }
            }
            .font(.system(size: 16, weight: .regular))
            .foregroundColor(.primary)
            .autocapitalization(.none)
            .disableAutocorrection(true)
            
            Button(action: {
                isVisible.toggle()
            }) {
                Image(systemName: isVisible ? "eye.slash" : "eye")
                    .font(.system(size: 16, weight: .light))
                    .foregroundColor(.black.opacity(0.5))
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.medium)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
        )
    }
}

#Preview {
    VStack(spacing: 20) {
        MinimalSecureField(
            text: .constant(""),
            placeholder: "Password",
            isVisible: .constant(false),
            icon: "lock"
        )
        
        MinimalSecureField(
            text: .constant("password123"),
            placeholder: "Password",
            isVisible: .constant(true),
            icon: "lock"
        )
    }
    .padding()
}
