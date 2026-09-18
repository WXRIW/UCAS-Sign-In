#if os(macOS)
import SwiftUI

/// Owned by the app rather than a window so closing or deactivating the main
/// window does not stop automatic attendance while the macOS app is running.
@MainActor
final class MacAutomaticAttendanceRunner: ObservableObject {
    private var task: Task<Void, Never>?

    func start(_ model: AppModel) {
        guard task == nil else { return }
        task = Task { [weak model] in
            while !Task.isCancelled, let model {
                await model.foregroundTick()
                do { try await Task.sleep(for: .seconds(30)) }
                catch { break }
            }
        }
    }

    deinit { task?.cancel() }
}
#endif
