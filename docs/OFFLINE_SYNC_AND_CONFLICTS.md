# PeerNest Offline Sync and Conflict Recovery

## Architecture

Offline recovery extends `PeerSyncCoordinator`; it is not a second synchronization engine. `FolderWatcher` still produces the local events, `PeerTransport` still supplies the authenticated encrypted channel, `RemoteOperationApplier` still applies non-file mutations, and the existing sender/receiver still transfer content.

`AppState` owns one `RecoveryRepository` for the application lifetime and injects it into each rebuilt coordinator. The actor serializes all recovery metadata updates. Tests that instantiate a coordinator directly can omit the repository and retain the earlier in-memory behavior.

The recovery root is:

`~/Library/Application Support/PeerNest/Recovery`

Its layout is:

- `recovery-v1.json`: atomic, schema-versioned metadata
- `Versions/Blobs/<hash-prefix>/<sha256>`: content-addressed file history and stable outgoing snapshots
- `Trash/<tombstone-id>/<item>`: app-managed recoverable deletions
- `Staging/<transfer-id>.partial`: resumable incoming data
- `recovery-v1.corrupt-<diagnostic-id>.json`: quarantined unreadable metadata

Metadata is written with atomic replacement, owner-only POSIX permissions, and complete-file-protection options. File contents never appear in the journal. Absolute shared-folder paths are not sent to peers and file contents are never logged.

## Journal schema (version 1)

Each `JournaledSyncOperation` contains its stable operation ID, local share and mapping IDs, origin and destination peer IDs, operation type, validated relative source/destination paths, expected version IDs, size/hash/modification metadata, an optional recovery-relative stable-content reference, timestamps, retry count, state, categorized last error, explicit dependencies, destructive flag, and Lamport sequence.

States are `queued`, `preparing`, `waitingForPeer`, `sending`, `awaitingAcknowledgment`, `completed`, `retryScheduled`, `conflicted`, `permanentlyFailed`, and `cancelled`. Invalid transitions and duplicate IDs fail. Every critical mutation persists before returning. Completed/cancelled rows may be compacted after a cutoff; pending destructive rows are never compacted.

On shutdown and sleep, the repository is flushed. Atomic writes mean a crash retains either the old complete document or the new complete document. Startup quarantines corrupt metadata and starts a recoverable empty document with a diagnostic rather than deleting recovery content.

## Ordering and coalescing

`OperationCoalescer` is mapping/share scoped. It collapses repeated file updates, create/update pairs, create/delete no-ops, update/delete pairs, duplicate directory creates, and rename chains. It never merges different shares/mappings.

`OperationDependencyResolver` honors explicit dependencies and adds conservative filesystem dependencies. Parent directories precede children; file creation precedes a rename; child deletions precede parent deletion. Cycles fall back to deterministic creation-time ordering rather than dropping work.

## Versions and logical clock

Every stable local synchronized mutation advances one installation-wide Lamport counter stored in `recovery-v1.json`. Receiving a remote value computes `max(local, remote) + 1`. This counter survives launches and gives deterministic ordering without treating wall-clock time as authoritative.

`FileVersion` includes a UUID, validated relative path, item type, size, modification time, SHA-256 where applicable, originating peer, Lamport sequence, optional parent ID, and creation time. `FileVersionComparator` uses IDs, content equality, parent links, and same-origin sequences. Versions from different origins without an ancestry proof are concurrent.

Stable local file contents are copied to the content-addressed store before sending. SHA-256 is streamed, copied data is verified, identical blobs deduplicate, and metadata remains separate. Restoring a blob atomically replaces the selected current path; the watcher then creates an ordinary new synchronization operation.

## Reconnect reconciliation and checkpoints

After authentication and mapping restoration, live sends pause for that mapping. Peers exchange bounded summaries containing share context, the mapping-local checkpoint, logical clock, up to 200 operation summaries, tombstones, and a continuation flag. Summaries expose a SHA-256 of paths, not paths themselves.

The coordinator coalesces and dependency-orders operations missing from the remote checkpoint, replays them through the normal encrypted sync messages, verifies acknowledgments, then exchanges completion. Repeated summaries, operations, acknowledgments, tombstones, and completion messages are idempotent.

A `MappingCheckpoint` records the highest contiguous sequence, acknowledged operation IDs, out-of-order sequence gaps, manifest/tombstone generations, and update time. An acknowledgment outside the contiguous range is retained until gaps arrive.

Reconciliation states are `idle`, `exchangingState`, `comparing`, `transferring`, `resolvingConflicts`, `verifying`, `completed`, `paused`, and `failed`. The UI reports progress and provides pause/retry. Unmatched manifest content is never automatically deleted.

## Conflict rules

Conflicts cover concurrent modification, delete-versus-modify, rename-versus-rename, create-versus-create, file-versus-directory, occupied destinations, and unsupported cases. Same content does not conflict. Different content from the same base does.

For content conflicts, the peer whose stable UUID sorts first keeps the original name. The losing version gets a deterministic name containing a sanitized peer display name and version-ID token. Extensions are preserved, names are bounded, occupied names get deterministic numeric suffixes, and an existing conflict ID never creates another copy.

`ConflictRecord` persists both versions, base version where known, type, timestamp, resolution, generated copies, decision, and diagnostic ID. Both bytes are preserved before replacement. The Recovery Center exposes Keep Both, Keep Local, and Keep Remote decisions. Resolution records are idempotent and can be sent over the authenticated channel.

Delete-versus-modify never deletes the newer modified content. The deletion remains a tombstone and the conflict stays visible until resolution.

## Tombstones and PeerNest Trash

A tombstone records its ID, local share/mapping, relative path, deleted version, deleting peer, deletion time, logical clock, optional expiration, restore state, and acknowledging peers. Stale tombstones cannot replace newer versions. Tombstones remain until conservatively expired and acknowledged.

Incoming remote deletion first moves existing content to PeerNest Trash and records/flushes the tombstone and trash metadata. Only then does PeerNest acknowledge the operation. Same-volume moves are atomic. A cross-volume fallback copies, verifies file hash or recursive directory size, and only then removes the source. All recovery-relative paths are containment checked.

Restore recreates the original path. If occupied, PeerNest uses an extension-preserving “Restored” copy name. Permanent deletion requires UI confirmation and removes metadata plus stored content; filesystem snapshots and backups may retain forensic copies.

If a user deletes a file directly in Finder while offline, PeerNest sees the event after the original bytes are already gone. The latest stable content-addressed version remains recoverable when one exists, but PeerNest cannot retroactively move that already-deleted object into Trash.

## Transfer resume

An operation ID is also its stable transfer ID. The receiver persists total size, chunk size, next sequential byte offset/chunk index, staging-relative path, final hash, source modification date, seven-day expiration, and a SHA-256 metadata token carried only in the authenticated session.

On reconnect, resume is accepted only when ID, size, hash, source modification time, token, staging file size, and chunk alignment agree. The sender validates the receiver offset, seeks without loading the file, and resumes sequential chunks. Completion rechecks size and full SHA-256 before atomic placement. A changed source rejects resume and restarts safely.

## Retention and storage

Defaults are 30 days for Trash, 30 days for version history, 20 versions per file, 5 GiB maximum recovery storage, and 1 GiB minimum free disk. Preferences are stored in the recovery repository. New recovery copies are rejected before crossing the configured capacity/free-space safety bounds. Cleanup runs off the main actor, reports eligible counts/bytes, removes oldest eligible versions first, removes expired staging records, and preserves active-conflict versions, pending-journal blobs, plus unacknowledged tombstones.

The Recovery Center shows journal entries, conflicts, Trash, versions, aggregate health, and storage. Sync health combines pending counts/bytes, unresolved conflicts, Trash/history usage, contact/success times, reconciliation progress, and latest error.

## Migration and crash recovery

Recovery metadata has an explicit schema integer. This is the first recovery schema, so upgrading from the previous app creates the repository without touching bookmarks, trusted peers, mappings, identities, or Finder data. Future non-current metadata is backed up before migration; unknown schema semantics fail safely.

Startup audits missing version/trash content, expired staging, and unindexed recovery content. Orphans are preserved and assigned diagnostic IDs. Applied operations remain idempotent through stable operation IDs and the existing registry; an operation is never guessed complete solely because a crash occurred after application.

## Security and privacy

Peer messages continue through the existing authenticated encrypted transport. Recovery paths and history are local; history bytes are sent only after a user restores them as current content. Secrets remain in Keychain. The journal contains user-relative filenames and peer IDs, so its owner-only local file should still be treated as sensitive. Recovery metadata is not separately encrypted at rest beyond macOS file protection and the user account’s storage encryption.

No entitlement was added. App Sandbox, scoped folder bookmarks, App Group, Bonjour, signing, bundle IDs, Finder integration, and deployment target remain unchanged.

## Known limitations

- The bounded summary has a continuation marker, but multi-page summary request/response beyond the first 200 summaries is not yet implemented; the durable local journal still replays all locally pending operations.
- Version ancestry is parent-link based, not a full vector clock; histories with missing ancestry conservatively conflict.
- The current watcher represents a rename without a paired old/new FSEvent as create/update plus delete, so some rename-versus-rename cases surface as conservative content/delete conflicts.
- Recovery metadata is atomic and protected but not field-level encrypted.
- Cleanup calculates critical disk pressure, but admission control for every possible copy race remains best effort.
- macOS UI automation still depends on a runnable signed test host; core recovery behavior is covered by unit and localhost integration tests.
