# Finder context-menu test

PeerNest uses one Finder Sync Extension (`com.apple.FinderSync`). It monitors the current user’s home directory, which includes Desktop, Documents, Downloads, and other home subfolders. Existing shared roots outside the home directory are added dynamically from the App Group snapshot. The filesystem root (`/`) is never registered.

## Manual verification

1. Build and run PeerNest from Xcode.
2. Open **System Settings → General → Login Items & Extensions**.
3. Open the PeerNest extension entry.
4. Enable the Finder integration.
5. Quit and reopen PeerNest.
6. Run `killall Finder` in Terminal.
7. Create a folder on Desktop named `PeerNestFinderTest`.
8. Right-click the folder.
9. Verify **Share with PeerNest** appears.
10. Select **Share with PeerNest**.
11. Verify PeerNest opens and comes forward.
12. If macOS requests access, select the same `PeerNestFinderTest` folder; verify it appears under Shared Folders.
13. Right-click the same folder again.
14. Verify **Stop Sharing with PeerNest** and **Show in PeerNest** appear.
15. Create a nested folder inside `PeerNestFinderTest`.
16. Right-click the nested folder.
17. Verify **Show Shared Folder in PeerNest** appears.
18. Use **Stop Sharing with PeerNest** on the shared root.
19. Verify `PeerNestFinderTest` and its contents remain on disk.
20. Verify only the PeerNest shared-folder record was removed.

## Troubleshooting

- **Extension is not listed:** Build and launch the containing `PeerNest.app`, then confirm it contains `Contents/PlugIns/PeerNestFinderExtension.appex`. The extension cannot be installed independently.
- **PeerNest is listed more than once:** Run `scripts/inspect-peernest-extensions.sh`. It prints DerivedData app copies, embedded extensions, PlugInKit registrations, duplicate identifiers, and missing registration paths. Review `scripts/reset-peernest-debug-extensions.sh` in its default dry-run mode. Only use `--execute` after checking every path it prints.
- **Context menu is missing:** Confirm the extension is enabled, the selected item is exactly one ordinary folder (not a file, package, or `.peernest` internal folder), and the folder is under the current user’s home directory or is a registered external shared root.
- **Finder is holding old extension code:** Quit PeerNest, run `killall Finder`, relaunch PeerNest, and try again.
- **Check PlugInKit:** Run `pluginkit -m -p com.apple.FinderSync | grep -i peernest`. If it is empty, run `pluginkit -m -D -A -v -v -v -i com.mustafayurtoglu.PeerNest.FinderExtension` to include disabled and superseded registrations, then confirm the enabled state in System Settings.
- **Stale DerivedData copies:** Run the inspection script first. The reset script only targets DerivedData whose `WorkspacePath` belongs to this repository and is dry-run unless `--execute` is supplied.
- **App Group mismatch:** Both the app and extension must contain `group.com.mustafayurtoglu.PeerNest` in their signed entitlements. A mismatch prevents commands and snapshots from crossing the process boundary.
- **Extension disabled:** Re-enable PeerNest under **Login Items & Extensions**, relaunch the app, and restart Finder.

The deterministic unit tests verify selection rules and Desktop scope without driving Finder. The final right-click interaction still requires the manual steps above because Finder’s contextual menu UI is system-owned.
