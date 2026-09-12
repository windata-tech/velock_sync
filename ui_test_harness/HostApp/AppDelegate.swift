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

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    var window: UIWindow?

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
        let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try? onePixelPNG.write(to: source.appendingPathComponent(fixtureImageName), options: .atomic)
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
