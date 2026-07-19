import CryptoKit
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    private let fixtureFileName = "velock-sync-e2e-proof.txt"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
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
        SHA-256: \(fixture.sha256)
        Bytes: \(fixture.byteCount)
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

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    var window: UIWindow?

    private func prepareFixture() -> (sha256: String, byteCount: Int) {
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
        return (sha256(fixture), fixture.count)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
