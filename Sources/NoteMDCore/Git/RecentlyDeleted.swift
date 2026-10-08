import Foundation

/// Which deleted files the Recently Deleted view lists.
///
/// The list is derived from git history, so emptying it can't destroy anything: it hides deletions by key instead,
/// and the files stay restorable from Version History.
public enum RecentlyDeleted {
    /// Identifies one deletion. A file deleted again in a later commit gets a new key and shows up again.
    public static func key(for file: GitDeletedFile) -> String {
        file.deletedIn.id + ":" + file.path
    }

    /// Whether `path` is in the repository's `assets/` folder (attachments, decision-5).
    public static func isAsset(_ path: String) -> Bool {
        path.split(separator: "/").first?.lowercased() == Attachments.folderName && path.contains("/")
    }

    /// Notes (and, with `includingAssets`, files in `assets/`) that aren't back in the repository and haven't been cleared.
    public static func visible(
        _ files: [GitDeletedFile], cleared: Set<String>, existingPaths: Set<String>, includingAssets: Bool = false
    ) -> [GitDeletedFile] {
        files.filter { file in
            (NoteMDCore.noteExtensions.contains((file.path as NSString).pathExtension.lowercased()) || (includingAssets && isAsset(file.path)))
                && !existingPaths.contains(file.path)
                && !cleared.contains(key(for: file))
        }
    }
}
