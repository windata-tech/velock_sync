import CryptoKit
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    private let fixtureFileName = "velock-sync-e2e-proof.txt"
    private let fixtureImageName = "velock-sync-e2e-proof.png"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    /// iOS 27 terminates apps that create their window without adopting the
    /// scene lifecycle, so the fixture UI is built for the connecting scene.
    func makeRootController() -> UIViewController {
        let fixture = prepareFixture()
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground

        let title = UILabel()
        title.text = "Velock Sync E2E Fixture"
        title.font = .preferredFont(forTextStyle: .title2)
        title.textAlignment = .center

        let details = UILabel()
        details.numberOfLines = 0
        details.textAlignment = .center
        details.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        details.accessibilityIdentifier = "fixture-details"
        details.text = """
        Source directory ready
        VelockSync-E2E-Source

        Replica directory ready
        VelockSync-E2E-Replica

        File: \(fixtureFileName)
        Source SHA-256: \(fixture.sourceSHA256)
        Source bytes: \(fixture.sourceByteCount)
        Replica restored: \(fixture.replicaSHA256 == nil ? "no" : "yes")
        Replica SHA-256: \(fixture.replicaSHA256 ?? "missing")
        Replica bytes: \(fixture.replicaByteCount.map(String.init) ?? "missing")
        """

        let stack = UIStackView(arrangedSubviews: [title, details])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.centerYAnchor),
        ])

        return controller
    }

    private func prepareFixture() -> (
        sourceSHA256: String,
        sourceByteCount: Int,
        replicaSHA256: String?,
        replicaByteCount: Int?
    ) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let source = documents.appendingPathComponent("VelockSync-E2E-Source", isDirectory: true)
        let replica = documents.appendingPathComponent("VelockSync-E2E-Replica", isDirectory: true)
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: replica, withIntermediateDirectories: true)

        let fixture = """
        VELOCK SYNC REAL DATA E2E
        This file must travel through encrypted WebDAV objects and be restored on a second iOS simulator.
        Fixture version: 2026-07-19
        """.data(using: .utf8)!
        try? fixture.write(to: source.appendingPathComponent(fixtureFileName), options: .atomic)
        // Keep an image beside the text fixture so the real image file-manager
        // import path can be exercised without depending on Photos state.
        // A one-pixel image cannot demonstrate a restored album. Generate a
        // clearly visible, synthetic proof image (no user photos or secrets).
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let proofImage = UIGraphicsImageRenderer(size: CGSize(width: 960, height: 640), format: format).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 960, height: 640))
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 60, y: 220, width: 250, height: 300))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 355, y: 220, width: 250, height: 300))
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 650, y: 220, width: 250, height: 300))
            ("VELOCK SYNC · PHOTO PROOF" as NSString).draw(
                at: CGPoint(x: 60, y: 80), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 44), .foregroundColor: UIColor.white])
            ("Synthetic tutorial image · 960 × 640" as NSString).draw(
                at: CGPoint(x: 60, y: 555), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 28), .foregroundColor: UIColor.white])
        }
        if let imageData = proofImage.pngData() {
            try? imageData.write(to: source.appendingPathComponent(fixtureImageName), options: .atomic)
        }
        let replicaData = try? Data(contentsOf: replica.appendingPathComponent(fixtureFileName))
        return (
            sourceSHA256: sha256(fixture),
            sourceByteCount: fixture.count,
            replicaSHA256: replicaData.map(sha256),
            replicaByteCount: replicaData?.count
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene,
              let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = appDelegate.makeRootController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
