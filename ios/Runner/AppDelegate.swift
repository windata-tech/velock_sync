import Flutter
import UniformTypeIdentifiers
import UIKit
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var selectedFolderAccess: SelectedFolderAccessController?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: "tech.windata.velock.sync.velock_sync.periodic_sync",
      frequency: NSNumber(value: 15 * 60)
    )
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func registerPowerStateChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "tech.windata.velock.sync/power_state",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "isCharging" else {
        result(FlutterMethodNotImplemented)
        return
      }
      UIDevice.current.isBatteryMonitoringEnabled = true
      result(
        UIDevice.current.batteryState == .charging ||
          UIDevice.current.batteryState == .full
      )
    }
  }

  private func registerExchangeChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "tech.windata.velock.sync/exchange",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "exchangeRoot" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let root = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: "group.tech.windata.velock.sync.exchange")?
        .appendingPathComponent("SyncExchange", isDirectory: true)
      result(root?.path)
    }
  }

  private func registerDiskSpaceChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "tech.windata.velock.sync/disk_space",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "availableBytes",
            let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        let values = try URL(fileURLWithPath: path, isDirectory: true).resourceValues(
          forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        )
        let bytes = values.volumeAvailableCapacityForImportantUsage
          ?? values.volumeAvailableCapacity.map { Int64($0) }
        guard let bytes, bytes >= 0 else {
          result(FlutterError(code: "DISK_SPACE", message: "Unable to inspect available storage.", details: nil))
          return
        }
        result(bytes)
      } catch {
        result(FlutterError(code: "DISK_SPACE", message: "Unable to inspect available storage.", details: nil))
      }
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    registerExchangeChannel(messenger)
    registerDiskSpaceChannel(messenger)
    registerPowerStateChannel(messenger)
    selectedFolderAccess = SelectedFolderAccessController(messenger: messenger)
  }
}

private final class SelectedFolderAccessController: NSObject, UIDocumentPickerDelegate {
  private let channel: FlutterMethodChannel
  private var pendingAuthorization: FlutterResult?
  private var activeSessions: [String: (url: URL, didStartAccess: Bool)] = [:]

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "tech.windata.velock.sync/selected_folder",
      binaryMessenger: messenger
    )
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "authorizeDirectory":
      authorizeDirectory(result: result)
    case "acquireDirectory":
      acquireDirectory(call.arguments, result: result)
    case "releaseDirectory":
      releaseDirectory(call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func authorizeDirectory(result: @escaping FlutterResult) {
    guard pendingAuthorization == nil else {
      result(FlutterError(
        code: "PICKER_BUSY",
        message: "A directory picker is already open.",
        details: nil
      ))
      return
    }
    guard let presenter = foregroundPresenter() else {
      result(FlutterError(
        code: "PICKER_UNAVAILABLE",
        message: "Unable to present the directory picker.",
        details: nil
      ))
      return
    }
    pendingAuthorization = result
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: [UTType.folder],
      asCopy: false
    )
    picker.delegate = self
    picker.allowsMultipleSelection = false
    presenter.present(picker, animated: true)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard let result = takePendingAuthorization() else { return }
    guard let url = urls.first else {
      result(nil)
      return
    }
    do {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey])
      guard values.isDirectory == true else {
        throw SelectedFolderAccessError.notDirectory
      }
      let bookmark = try url.bookmarkData(
        options: [],
        includingResourceValuesForKeys: [.isDirectoryKey],
        relativeTo: nil
      )
      guard !bookmark.isEmpty else {
        throw SelectedFolderAccessError.emptyBookmark
      }
      result(bookmark.base64EncodedString())
    } catch {
      result(folderError(error, code: "BOOKMARK_CREATE"))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    takePendingAuthorization()?(nil)
  }

  private func acquireDirectory(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let arguments = arguments as? [String: Any],
          let encodedBookmark = arguments["bookmark"] as? String,
          let bookmark = Data(base64Encoded: encodedBookmark),
          !bookmark.isEmpty else {
      result(folderError(SelectedFolderAccessError.invalidBookmark, code: "BOOKMARK_INVALID"))
      return
    }
    do {
      var isStale = false
      let url = try URL(
        resolvingBookmarkData: bookmark,
        options: [.withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      guard !isStale else { throw SelectedFolderAccessError.staleBookmark }
      let didStartAccess = url.startAccessingSecurityScopedResource()
      do {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
          throw SelectedFolderAccessError.notDirectory
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
          throw SelectedFolderAccessError.unreadableDirectory
        }
      } catch {
        if didStartAccess { url.stopAccessingSecurityScopedResource() }
        throw error
      }
      let token = UUID().uuidString
      activeSessions[token] = (url, didStartAccess)
      result(["token": token, "path": url.path])
    } catch {
      result(folderError(error, code: "BOOKMARK_RESOLVE"))
    }
  }

  private func releaseDirectory(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let arguments = arguments as? [String: Any],
          let token = arguments["token"] as? String,
          !token.isEmpty else {
      result(folderError(SelectedFolderAccessError.invalidToken, code: "SESSION_INVALID"))
      return
    }
    guard let session = activeSessions.removeValue(forKey: token) else {
      result(folderError(SelectedFolderAccessError.unknownToken, code: "SESSION_UNKNOWN"))
      return
    }
    if session.didStartAccess {
      session.url.stopAccessingSecurityScopedResource()
    }
    result(nil)
  }

  private func takePendingAuthorization() -> FlutterResult? {
    defer { pendingAuthorization = nil }
    return pendingAuthorization
  }

  private func topViewController(from root: UIViewController?) -> UIViewController? {
    if let presented = root?.presentedViewController {
      return topViewController(from: presented)
    }
    if let navigation = root as? UINavigationController {
      return topViewController(from: navigation.visibleViewController)
    }
    if let tabs = root as? UITabBarController {
      return topViewController(from: tabs.selectedViewController)
    }
    return root
  }

  private func foregroundPresenter() -> UIViewController? {
    let foregroundScenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .filter { $0.activationState == .foregroundActive }
    let window = foregroundScenes
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)
      ?? foregroundScenes.flatMap(\.windows).first(where: { !$0.isHidden })
    return topViewController(from: window?.rootViewController)
  }

  private func folderError(_ error: Error, code: String) -> FlutterError {
    FlutterError(code: code, message: error.localizedDescription, details: nil)
  }

  deinit {
    for session in activeSessions.values where session.didStartAccess {
      session.url.stopAccessingSecurityScopedResource()
    }
  }
}

private enum SelectedFolderAccessError: LocalizedError {
  case invalidBookmark
  case emptyBookmark
  case staleBookmark
  case notDirectory
  case unreadableDirectory
  case invalidToken
  case unknownToken

  var errorDescription: String? {
    switch self {
    case .invalidBookmark: "The directory bookmark is invalid."
    case .emptyBookmark: "The directory bookmark is empty."
    case .staleBookmark: "The directory authorization is stale."
    case .notDirectory: "The selected item is not a directory."
    case .unreadableDirectory: "The selected directory is not readable."
    case .invalidToken: "The directory access token is invalid."
    case .unknownToken: "The directory access session is not active."
    }
  }
}
