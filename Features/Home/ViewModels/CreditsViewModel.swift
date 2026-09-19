import Foundation
import Combine

@MainActor
final class CreditsViewModel: ObservableObject {
    @Published private(set) var snapshot: CreditsSnapshot?
    @Published private(set) var isLoading = false
    private let store: CreditsStore
    private var request: Task<CreditsSnapshot?, Never>?
    private var generation = 0

    init(store: CreditsStore = .shared) { self.store = store }

    func load(force: Bool = false) async {
        request?.cancel()
        generation += 1
        let currentGeneration = generation
        isLoading = true
        let local = await store.local()
        guard !Task.isCancelled, generation == currentGeneration else {
            if generation == currentGeneration { isLoading = false }
            return
        }
        snapshot = local
        let store = store
        let task = Task<CreditsSnapshot?, Never> {
            do {
                return try await store.refresh(force: force)
            } catch {
                // The store returns user-facing failures; thrown errors indicate cancellation.
                return nil
            }
        }
        request = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard generation == currentGeneration else { return }
        if !Task.isCancelled, let result { snapshot = result }
        isLoading = false
        request = nil
    }

    func cancel() {
        generation += 1
        request?.cancel()
        request = nil
        isLoading = false
    }
}
