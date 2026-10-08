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

    /// Files with a listed extension that aren't back in the repository and haven't been cleared.
    public static func visible(
        _ files: [GitDeletedFile], cleared: Set<String>, existingPaths: Set<String>, extensions: Set<String> = NoteMDCore.noteExtensions
    ) -> [GitDeletedFile] {
        files.filter { file in
            extensions.contains((file.path as NSString).pathExtension.lowercased())
                && !existingPaths.contains(file.path)
                && !cleared.contains(key(for: file))
        }
    }
}
