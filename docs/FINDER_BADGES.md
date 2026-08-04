# Finder Badges

The main app writes an atomic `FinderBadgeSnapshot.plist` into the App Group. Stable identifiers are `peernest.upToDate`, `peernest.syncing`, `peernest.offlineChangesPending`, `peernest.conflict`, `peernest.paused`, `peernest.error`, and `peernest.unknown`.

The extension reads only the lightweight snapshot and shared-folder bookmarks; it never uses networking. Corrupt or missing data and snapshots older than five minutes resolve to unknown. Only shared roots receive state badges in this version, avoiding recursive Finder work on large folder trees.
