import SwiftUI

struct MinimalTextField: View {
    @Binding var text: String
    let placeholder: String
    let icon: String
    
    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .light))
                .foregroundColor(.primary)
                .frame(width: 24)
            
            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(.black.opacity(0.5)))
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(.primary)
                .autocapitalization(.none)
                .disableAutocorrection(true)
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
        MinimalTextField(
            text: .constant(""),
            placeholder: "Username",
            icon: "person"
        )
        
        MinimalTextField(
            text: .constant("demo@example.com"),
            placeholder: "Email",
            icon: "envelope"
        )
    }
    .padding()
}
