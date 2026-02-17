import SwiftUI
import Combine

@MainActor
final class EventRegistrationViewModel: ObservableObject {
    @Published var selectedTab: Int = 0
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    init() {}
}
