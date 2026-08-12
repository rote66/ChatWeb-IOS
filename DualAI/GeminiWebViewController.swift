import UIKit

final class GeminiWebViewController: EmbeddedWebViewController {
    init(preferences: AppPreferences = .shared) {
        super.init(service: .gemini, preferences: preferences)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
