import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let exchangeChannel = FlutterMethodChannel(
      name: "tech.windata.velock.sync/exchange",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    exchangeChannel.setMethodCallHandler { call, result in
      guard call.method == "exchangeRoot" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let root = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: "group.tech.windata.velock.sync.exchange")?
        .appendingPathComponent("SyncExchange", isDirectory: true)
      result(root?.path)
    }

    super.awakeFromNib()
  }
}
