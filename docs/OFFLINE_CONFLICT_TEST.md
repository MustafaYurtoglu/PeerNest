# PeerNest Offline and Conflict Manual Test

Use two Macs on the same LAN with a Debug or signed Development build. Keep Console free of private file-content logging. Use disposable folders with known sample data.

1. Launch PeerNest on Mac A and Mac B.
2. Pair the Macs and confirm both displayed verification codes before trusting.
3. On A, share a disposable folder with B as Read & Write; accept it into an empty disposable folder on B.
4. Create `baseline.txt` on A, wait for both Sync & Recovery views to say **Up to Date**, and compare bytes on B.
5. Disable Wi-Fi on B (or disconnect B in PeerNest) and confirm B reports **Offline Changes Pending** after a local edit.
6. While disconnected, create `A-only.txt` and edit `baseline.txt` on A. Create `B-only.txt` and a nested `Folder/child.txt` on B.
7. Quit and relaunch B. Confirm its Pending list still contains the queued relative paths, IDs, timestamps, states, and retry counts.
8. Re-enable Wi-Fi. Confirm both peers authenticate, enter **Reconciling**, exchange checkpoints, and keep live sync paused during replay.
9. Confirm `A-only.txt`, `B-only.txt`, and `Folder/child.txt` arrive on both sides with matching SHA-256 hashes. Confirm Pending returns to zero.
10. Disconnect again after both sides have the same `conflict.txt`.
11. Edit `conflict.txt` to different content on A and B without reconnecting.
12. Reconnect and confirm a conflict is shown with type, relative path, local/remote versions, detection time, resolution, and diagnostic ID.
13. Confirm the deterministic peer-ID winner keeps `conflict.txt`, the other bytes appear in one extension-preserving conflict copy, and repeated reconnects create no extra copies.
14. Choose **Keep Both** and confirm the conflict becomes resolved without either stored version disappearing.
15. Repeat with a second file, choose **Keep Local**, and verify the losing bytes remain in Versions before any replacement.
16. Repeat with a third file, choose **Keep Remote**, and verify the prior local bytes remain recoverable in Versions.
17. Disconnect with identical `delete-modify.txt`; delete it on A and modify it on B. Reconnect.
18. Confirm **deleteVsModify** appears, B’s modified bytes remain at a recoverable path, and a tombstone is recorded rather than silently deleting or resurrecting stale content.
19. Create a nested directory on A, wait for B, then delete it remotely. Confirm B moves the full tree into PeerNest Trash before acknowledging.
20. In B’s Sync & Recovery › Trash, inspect original path, deleting device, date, size, and remaining retention. Press **Restore** and confirm the full directory returns and synchronizes as a new operation.
21. Delete another item, create a replacement at its original path, then restore. Confirm PeerNest creates a safe “Restored” copy and leaves the replacement unchanged.
22. Use **Delete Permanently**, cancel once, then confirm. Verify the item and its metadata disappear only after confirmation.
23. Replace a file several times from alternate peers. In Versions, confirm timestamps, source peers, sizes, hash abbreviations, and reasons; identical content should reuse one blob.
24. Select an older version and press **Restore as Current**. Confirm it becomes a new normal sync operation and the immediately replaced bytes remain recoverable.
25. Start a large transfer, note its progress, disconnect mid-transfer, quit both apps, relaunch, and reconnect. Confirm the receiver resumes at a nonzero validated offset and final SHA-256 matches.
26. Change the source file before a second resume attempt. Confirm PeerNest rejects the prior offset and restarts rather than combining versions.
27. Quit both apps with multiple offline operations, relaunch, and confirm journal states plus Lamport sequences survive.
28. Lose an acknowledgment by disconnecting immediately after the destination applies a change. Reconnect and verify duplicate delivery is idempotent and does not create a conflict copy.
29. In Storage, verify Trash/history usage, 30-day defaults, 20-version maximum, 5 GiB limit, and 1 GiB free-space threshold.
30. Run cleanup with an unresolved conflict and unacknowledged tombstone. Confirm their bytes are retained; only eligible data is removed.
31. Copy `recovery-v1.json` somewhere safe, corrupt the working copy while PeerNest is stopped, then relaunch. Confirm it is quarantined with a diagnostic instead of deleting content. Restore the saved metadata before continuing normal use.
32. Press **Enable macOS Notifications…** only if testing notifications. Confirm macOS permission is requested only after this explicit action and ordinary successful real-time changes do not notify.
33. Confirm Finder badges, Finder commands, pairing, auto-connect, menu bar state, sleep/wake recovery, and localhost Debug controls still behave as documented in the existing test guides.
34. In a Release build, confirm localhost Debug controls/plaintext strings are absent and all peer sync still requires the authenticated encrypted session.

Record both PeerNest versions, macOS versions, peer IDs (not private paths), diagnostic IDs, file hashes, reconciliation duration, resume offset, and any unexpected recovery-store growth with the test result.
