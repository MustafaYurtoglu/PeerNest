# macOS Lifecycle

`ServiceContainer` owns the single `AppState`, preferences, login-item manager, lifecycle coordinator, power observer, and network-path observer. Closing the main window never equals explicit quit. With background sync enabled, services continue; when disabled, closing the final main window pauses synchronization while the menu bar remains available.

Explicit Quit flushes recovery persistence and stops polling, Bonjour, peer sessions, synchronization, watchers, and scoped folder access. Sleep flushes state and disconnects; wake is debounced before restarting local-network services. Interface changes restart discovery once through the coordinator. Dock visibility uses the regular/accessory activation policy and can be changed at runtime; macOS may briefly reorder application focus.
