import UIKit

enum WebErrorKind {
    case offline
    case loadFailed
    case processTerminated
    case unsupported
    case loginBlocked
    case downloadUnavailable
    case permissionDenied

    var symbolName: String {
        switch self {
        case .offline: return "wifi.slash"
        case .loadFailed: return "exclamationmark.triangle"
        case .processTerminated: return "arrow.clockwise"
        case .unsupported: return "safari"
        case .loginBlocked: return "person.crop.circle.badge.exclamationmark"
        case .downloadUnavailable: return "arrow.down.circle"
        case .permissionDenied: return "lock.shield"
        }
    }
}

final class WebErrorViewController: UIViewController {
    private let kind: WebErrorKind
    private let headline: String
    private let detail: String
    private let primaryTitle: String
    private let secondaryTitle: String?
    private let primaryAction: () -> Void
    private let secondaryAction: (() -> Void)?

    init(kind: WebErrorKind,
         headline: String,
         detail: String,
         primaryTitle: String,
         secondaryTitle: String? = nil,
         primaryAction: @escaping () -> Void,
         secondaryAction: (() -> Void)? = nil) {
        self.kind = kind
        self.headline = headline
        self.detail = detail
        self.primaryTitle = primaryTitle
        self.secondaryTitle = secondaryTitle
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let imageView = UIImageView(image: UIImage(systemName: kind.symbolName))
        imageView.tintColor = .secondaryLabel
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalToConstant: 42).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 42).isActive = true
        imageView.isAccessibilityElement = false

        let titleLabel = UILabel()
        titleLabel.text = headline
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        let detailLabel = UILabel()
        detailLabel.text = detail
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        let primaryButton = makeButton(title: primaryTitle, selector: #selector(didTapPrimary))
        let stack = UIStackView(arrangedSubviews: [imageView, titleLabel, detailLabel, primaryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.setCustomSpacing(20, after: detailLabel)

        if let secondaryTitle = secondaryTitle {
            let button = makeButton(title: secondaryTitle, selector: #selector(didTapSecondary))
            button.setTitleColor(.secondaryLabel, for: .normal)
            stack.addArrangedSubview(button)
        }

        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 440)
        ])
    }

    private func makeButton(title: String, selector: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.addTarget(self, action: selector, for: .touchUpInside)
        button.accessibilityLabel = title
        return button
    }

    @objc private func didTapPrimary() { primaryAction() }
    @objc private func didTapSecondary() { secondaryAction?() }
}
