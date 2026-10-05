import SwiftUI

extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
    
    @ViewBuilder
    func `if`<Transform: View>(
        _ condition: Bool,
        transform: (Self) -> Transform
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }

    /// Liquid Glass on iOS 26; iOS 18 falls back to a material in the same shape.
    @ViewBuilder
    func adaptiveGlass<S: Shape>(tint: Color? = nil, interactive: Bool = false, in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
        } else {
            background {
                shape.fill(.regularMaterial)
                if let tint { shape.fill(tint) }
            }
        }
    }

    @available(iOS 26.0, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}
