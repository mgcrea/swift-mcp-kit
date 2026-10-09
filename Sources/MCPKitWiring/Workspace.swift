import Foundation

#if os(macOS)
  import AppKit
#endif

/// LaunchServices, as far as this package asks it: where an app is installed, and which app a
/// link opens in.
///
/// `NSWorkspace` on the Mac. Under Mac Catalyst the class is marked unavailable, yet it is in
/// every Catalyst process, since AppKit draws the windows; UIKit has no way to ask either
/// question, so the same two methods are sent through the Objective-C runtime. Both take one
/// object and return one, which is what `perform(_:with:)` can carry.
enum Workspace {
  static func application(bundleIdentifier: String) -> URL? {
    #if os(macOS)
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    #elseif targetEnvironment(macCatalyst)
      send("URLForApplicationWithBundleIdentifier:", bundleIdentifier as NSString)
    #else
      nil
    #endif
  }

  /// The app LaunchServices opens `url` in, which for a custom scheme is whichever app claimed
  /// it: not necessarily the one that was meant to.
  static func application(toOpen url: URL) -> URL? {
    #if os(macOS)
      NSWorkspace.shared.urlForApplication(toOpen: url)
    #elseif targetEnvironment(macCatalyst)
      send("URLForApplicationToOpenURL:", url as NSURL)
    #else
      nil
    #endif
  }

  #if targetEnvironment(macCatalyst)
    private static func send(_ selector: String, _ argument: NSObject) -> URL? {
      guard let workspace = NSClassFromString("NSWorkspace") as AnyObject?,
        let shared = workspace.perform(NSSelectorFromString("sharedWorkspace"))?
          .takeUnretainedValue() as? NSObject
      else { return nil }
      return shared.perform(NSSelectorFromString(selector), with: argument)?
        .takeUnretainedValue() as? URL
    }
  #endif
}
