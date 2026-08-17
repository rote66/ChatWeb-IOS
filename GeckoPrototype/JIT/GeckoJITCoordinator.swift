import Foundation

/// Tracks JIT readiness reported by Gecko. This type does not enable JIT by
/// itself; deployment-specific enablement stays behind the native adapter.
@MainActor
final class GeckoJITCoordinator {
    struct Child: Equatable {
        let processID: Int32
        let processType: String
        var state: GeckoJITRuntimeState
    }

    private(set) var children: [Int32: Child] = [:]

    func childDidStart(processID: Int32, processType: String) {
        guard processID > 0 else { return }
        children[processID] = Child(
            processID: processID,
            processType: processType,
            state: .unresolved
        )
    }

    func childDidChangeJITState(
        processID: Int32,
        state: GeckoJITRuntimeState
    ) {
        guard var child = children[processID] else { return }
        child.state = state
        children[processID] = child
    }

    func childDidExit(processID: Int32) {
        children.removeValue(forKey: processID)
    }

    var geminiContentState: GeckoJITRuntimeState {
        let contentChildren = children.values.filter {
            let value = $0.processType
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return value == "tab" || value == "web" || value == "webisolated"
        }

        if contentChildren.contains(where: { $0.state == .enabled }) {
            return .enabled
        }
        if let failed = contentChildren.compactMap({ child -> Int32? in
            if case let .failed(reason) = child.state { return reason }
            return nil
        }).first {
            return .failed(reason: failed)
        }
        if let degraded = contentChildren.compactMap({ child -> Int32? in
            if case let .degradedNoJIT(reason) = child.state { return reason }
            return nil
        }).first {
            return .degradedNoJIT(reason: degraded)
        }
        return .unresolved
    }

    var productionReady: Bool {
        geminiContentState == .enabled
    }
}
