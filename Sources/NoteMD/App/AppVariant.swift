import Foundation

/// Build flavor facts patched into Info.plist by scripts/build-app.sh.
enum AppVariant {
    private static func string(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    /// `release`, `dev` or `test`.
    static let name = string("AppVariant") ?? "release"
    static let urlScheme = string("AppURLScheme") ?? "notemd"
    /// Background agent build: never activates or steals focus.
    static let isBackground = (Bundle.main.object(forInfoDictionaryKey: "AppBackground") as? Bool) ?? false
    static let displayName = string("CFBundleDisplayName") ?? "NoteMD"
}
