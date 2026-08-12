import AVFoundation
import Photos
import UIKit
import WebKit

final class PermissionManager {
    private weak var presenter: UIViewController?
    private let policy: NavigationPolicy

    init(presenter: UIViewController, service: WebService) {
        self.presenter = presenter
        policy = NavigationPolicy(service: service)
    }

    @available(iOS 15.0, *)
    func requestWebMediaPermission(originHost: String,
                                   type: WKMediaCaptureType,
                                   completion: @escaping (WKPermissionDecision) -> Void) {
        guard let originURL = URL(string: "https://\(originHost)/"),
              policy.isTrustedURL(originURL),
              let presenter = presenter else {
            completion(.deny)
            return
        }

        let resourceName: String
        switch type {
        case .camera: resourceName = "相机"
        case .microphone: resourceName = "麦克风"
        case .cameraAndMicrophone: resourceName = "相机和麦克风"
        @unknown default:
            completion(.deny)
            return
        }

        let alert = UIAlertController(
            title: "允许网页使用\(resourceName)？",
            message: "请求来自可信的\(policy.serviceName)页面。本次允许仍受 iOS 系统权限控制。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "不允许", style: .cancel) { _ in completion(.deny) })
        alert.addAction(UIAlertAction(title: "继续", style: .default) { [weak self] _ in
            self?.requestSystemPermissions(for: type) { granted in
                completion(granted ? .grant : .deny)
                if !granted { self?.showSettingsHint(resourceName: resourceName) }
            }
        })
        presenter.present(alert, animated: true)
    }

    @available(iOS 15.0, *)
    private func requestSystemPermissions(for type: WKMediaCaptureType,
                                          completion: @escaping (Bool) -> Void) {
        switch type {
        case .camera:
            requestAccess(for: .video, completion: completion)
        case .microphone:
            requestAccess(for: .audio, completion: completion)
        case .cameraAndMicrophone:
            requestAccess(for: .video) { [weak self] cameraGranted in
                guard cameraGranted else { completion(false); return }
                self?.requestAccess(for: .audio, completion: completion)
            }
        @unknown default:
            completion(false)
        }
    }

    private func requestAccess(for mediaType: AVMediaType, completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func showSettingsHint(resourceName: String) {
        guard let presenter = presenter else { return }
        let alert = UIAlertController(
            title: "\(resourceName)权限未开启",
            message: "可在系统设置中调整权限，或使用 Safari 继续。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "打开设置", style: .default) { _ in
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        })
        presenter.present(alert, animated: true)
    }
}
