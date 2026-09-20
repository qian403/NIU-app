import Combine
import Foundation

@MainActor
final class SettingsConnectionViewModel: ObservableObject {
    @Published private(set) var statuses: [ConnectionService: ConnectionStatus] = [:]
    private let service: ConnectionStatusService
    private var generation = UUID()

    init(service: ConnectionStatusService) {
        self.service = service
    }

    func reset() {
        generation = UUID()
        statuses = [:]
    }

    func refresh() async {
        guard !Task.isCancelled else { return }
        let currentGeneration = UUID()
        generation = currentGeneration
        statuses = Dictionary(uniqueKeysWithValues: ConnectionService.allCases.map { ($0, .checking) })
        await withTaskGroup(of: (ConnectionService, ConnectionStatus?).self) { group in
            for target in ConnectionService.allCases {
                group.addTask { [service] in
                    do {
                        return (target, try await service.check(target))
                    } catch {
                        return (target, nil)
                    }
                }
            }
            for await (target, status) in group {
                guard generation == currentGeneration, !Task.isCancelled else { continue }
                statuses[target] = status ?? .unchecked
            }
        }
        if generation == currentGeneration, Task.isCancelled {
            reset()
        }
    }
}
