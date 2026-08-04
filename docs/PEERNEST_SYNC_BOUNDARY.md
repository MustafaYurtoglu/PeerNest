# PeerNest synchronization boundary

A `SharedFolder` is one recursive synchronization boundary. Its root and every descendant belong to that share. The root's parent, siblings, and their descendants are excluded.

Synchronization identities use a shared-folder UUID and a validated relative path. Absolute paths are local implementation details and must never be sent as protocol identities. Relative paths that are absolute, empty, malformed, or contain `.` or `..` components are rejected.

Containment is checked using standardized URL components and symlink-resolved URLs, not string prefixes. A symbolic link that resolves outside the shared root is rejected and must not be followed. PeerNest's `.peernest` metadata directory, `.DS_Store`, and common temporary editor files are ignored.

Overlapping roots are not supported in the first version. A root cannot duplicate an existing share, sit below an existing share, or contain an existing share.

Shares support prototype read/write synchronization over a validated `ShareMapping`. Network messages carry only sender and receiver share UUIDs plus relative paths; absolute local paths are never part of the peer protocol. Incoming files are staged under `.peernest/staging`, verified, and atomically installed before their watcher events are suppressed.

Initial synchronization is conservative: unmatched destination content is never deleted. Differing files at the same relative path are preserved as peer-labelled conflict copies. Rename and move operations carry validated source and destination relative paths within the same shared-folder UUID.

The localhost hello/ack identity is diagnostic, not authentication. Production networking must add an authenticated encrypted channel before expanding beyond this explicitly configured localhost prototype.
