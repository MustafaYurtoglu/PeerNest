# LAN pairing and security

## Scope and architecture

PeerNest communicates only between peers on the same reachable local network. There is no relay, cloud account, centralized server, remote-access service, launch daemon, or multi-hop routing. The main app owns all discovery and networking. The Finder extension remains network-free and communicates with the app only through the existing App Group command queue.

The LAN milestone extends the existing `PeerServer` → `PeerConnection` → length-prefixed `PeerMessage` → `PeerTransport` → `PeerSyncCoordinator` stack. It does not create a second socket or synchronization implementation. Normal operation adds Bonjour before connection and an authenticated encrypted frame layer inside `PeerTransport`. The existing plaintext localhost path is compiled only in DEBUG and is visibly labeled as a prototype in the UI.

## Bonjour discovery

The service type is exactly `_peernest._tcp`. `PeerServer` binds either the configured DEBUG port or a system-selected production port. Its `NWListener` advertises that actual listener through `NWListener.Service`; Network.framework handles endpoint resolution, IPv4/IPv6 selection, interface scope, and duplicate service-name renaming.

The advertised name is derived from `PeerIdentity.displayName`, with control characters and `/` removed and the UTF-8 representation limited to 63 bytes. The TXT record contains only:

- `pv`: framed protocol version
- `av`: app version
- `caps`: protocol capability identifiers
- `did`: a 16-character SHA-256-derived discovery identifier for the stable peer ID
- `pair`: whether pairing is available

It never contains a local path, folder/share name, user account name, public or private cryptographic credential, or file metadata.

`BonjourBrowser` browses only `_peernest._tcp` with TXT records enabled. `BonjourDiscoveryRegistry` excludes the local discovery ID, merges results that share a stable discovery ID, retains disappearing peers as unavailable, tolerates malformed TXT values, and reports incompatible protocol versions. Network.framework service endpoints are passed directly to `NWConnection`, so the code does not parse or assume IPv4 addresses. Wi-Fi and wired Ethernet interfaces are surfaced in the model when Network.framework provides them.

Browsing, advertising/listening, sessions, and watchers are stopped during application shutdown. Browser result delivery and observable UI state are confined to the main actor.

## Local-network privacy and sandboxing

The main app uses [Info.plist](../PeerNest/Info.plist) because `NSBonjourServices` must be an array. It declares:

- `NSBonjourServices`: one value, `_peernest._tcp`
- `NSLocalNetworkUsageDescription`: “PeerNest uses your local network to discover and synchronize folders with devices you choose.”

The main app entitlements were not broadened: App Sandbox, the existing App Group, app-scoped security bookmarks, outgoing network client, and incoming network server remain enabled. No broad file permission was added. The Finder extension entitlements remain App Sandbox + App Group + app-scoped bookmarks, with no network client or server entitlement.

## Long-term device identity and Keychain

On first production launch, `DeviceIdentityStore` generates a CryptoKit `Curve25519.Signing.PrivateKey`. Its raw private representation is stored as a generic-password Keychain item:

- service: `com.mustafayurtoglu.PeerNest.device-identity`
- account: `curve25519-signing-private-key-v1`
- accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- data-protection Keychain enabled

The default application Keychain namespace is sufficient, so no Keychain sharing access group or Apple Developer portal capability was added. The private key is never Codable, never written to UserDefaults, never placed in a protocol payload, and never logged. `SecureKeyStore` isolates Keychain operations and has a process-only implementation for tests.

The public signing key is exposed during pairing. Its trust fingerprint is SHA-256, displayed as uppercase four-hex-character groups. The fingerprint, public key, peer ID, display name, dates, last Bonjour name, auto-connect setting, and trust state are non-secret and persist through `TrustedPeerStore` in UserDefaults.

## Pairing protocol

Pairing is the only operation allowed for an untrusted peer. Selecting Pair creates an ephemeral session with a two-minute lifetime. Both peers exchange a `PairingHello` containing a session/message ID, role, stable peer ID, display name, protocol version, long-term public signing key, ephemeral Curve25519 key-agreement public key, 32 random nonce bytes, and timestamps.

The canonical transcript is sorted-key JSON containing the initiator and responder hellos in fixed role order. Both sides perform Curve25519 key agreement and use CryptoKit HKDF-SHA256 with:

- salt: SHA-256 of the canonical transcript
- context: `PeerNest pairing verification v1`
- output: 32 bytes

The first eight derived bytes are reduced modulo 1,000,000 and shown as a zero-padded six-digit code. The displayed code is never transmitted. Users must compare it and confirm on both Macs. Each confirmation signs a domain-separated transcript digest plus the confirming peer ID with its long-term Curve25519 signing key. Trust is saved only after both valid signed confirmations.

Sessions reject duplicate message IDs, mismatched peers/sessions, expired messages, incompatible versions, invalid signatures, and confirmation before a transcript exists. Outgoing and incoming attempts are bounded to five per minute. Simultaneous requests resolve deterministically: the lexicographically lower stable peer ID keeps the initiator session and the higher ID becomes responder. Cancellation/rejection creates no trust and clears ephemeral session state.

## Trusted identity validation and identity changes

Normal connection setup sends an ephemeral secure-session hello containing the peer ID, protocol/capabilities, long-term public identity, ephemeral agreement key, nonce, timestamp, and a signature over all those fields. The receiver requires an existing `.trusted` record, compares the presented public identity byte-for-byte with the pinned key, and verifies the signature using that pinned key.

If the public identity differs, `TrustedPeerStore` marks the record `.identityChanged`, automatic connection is blocked, and the UI shows an identity warning. PeerNest never silently replaces the pin. Trusting the replacement requires a new explicit code-verified pairing. Revoked peers and unknown peers cannot establish a normal session.

## Encrypted session design

PeerNest uses the allowed CryptoKit authenticated-encryption design over the existing length-prefixed Network.framework TCP connection. It does not implement a home-grown cipher.

Each connection creates fresh Curve25519 key-agreement keys and random nonces. Both sides build a canonical transcript bound to the session ID, both stable peer IDs, and both nonces, then derive a unique 256-bit session key with HKDF-SHA256 and the context `PeerNest authenticated session v1`.

Normal messages—including the existing hello/ack handshake, manifests, sync operations, file-transfer start/chunks/completion, operation acknowledgments, errors, pings, and pongs—are encoded as complete inner `PeerMessage` values and sealed with CryptoKit ChaChaPoly. The outer frame contains only a `SecureEnvelope`.

Authenticated associated data includes:

- session ID
- authenticated sender peer ID
- protocol version
- inner message type
- monotonically increasing sequence number

The 96-bit nonce uses a deterministic, distinct direction marker plus the 64-bit sequence number. The per-connection session key is fresh, directions cannot collide, sequence exhaustion is rejected, and keys are never reused across reconnects. The receiver requires the exact next sequence number, validates the expected directional nonce, authenticates before decoding the inner message, and never forwards unauthenticated plaintext to sync services. Replays, gaps/out-of-order frames, metadata substitution, tampering, wrong sessions, and wrong peer IDs are rejected. Three authentication failures close the connection.

Release builds have no plaintext normal-traffic case. DEBUG exposes an explicit `.debugPlaintext` mode only to preserve the localhost two-instance test workflow. There is no silent downgrade.

## Reconnection and duplicate ownership

When Bonjour reports a trusted peer as available, PeerNest auto-connects only if the record is `.trusted`, auto-connect is enabled, the user has not manually disconnected it for this app session, and the local peer owns the outbound primary connection. Ownership is deterministic: the lexicographically lower stable peer ID initiates; the higher peer accepts. This prevents both peers from continuously racing outbound connections.

Reconnect uses bounded exponential delays from 1 to 32 seconds. Only one active transport connection is accepted at a time. `lastConnectedAt` is updated only after the pinned, encrypted hello/ack handshake reaches ready. Manual Connect and Disconnect remain available; manual Disconnect pauses auto-connect until the user connects again or relaunches.

## Revocation

Forget Device shows: “PeerNest will stop trusting this device. Your local files will not be deleted.” Forgetting disconnects that peer, disables its share mappings, disables auto-connect, and stores a `.revoked` marker with the previous fingerprint. It does not remove shared folders or user files. A revoked device must complete explicit pairing again before normal traffic is accepted.

## Share invitations and mappings

Trust does not grant folder access. With an authenticated peer connected, a sender chooses one local `SharedFolder`, an access mode, and sends a time-limited `ShareInvitation` containing only IDs, a display name, access mode, timestamps, and optional aggregate item/size estimates. Absolute sender paths are never transmitted.

The receiver sees the sender, folder display name, access mode, and optional estimates. Acceptance requires an explicit folder picker choice, producing a local security-scoped `SharedFolder`. Only then does the receiver return its local share ID and create a receiver-role `ShareMapping`; the sender creates an owner-role mapping after the acceptance response. `ShareMappingStore` persists accepted mappings and rejects duplicate peer/share or destination mappings. Rejection/expiration creates no mapping. Synchronization remains unavailable until the mapping exists and is enabled.

Stopping or pausing a mapping never deletes files. Forgetting a peer disables related mappings but retains their files and the local shared-folder registrations.

## Access modes

`readWrite` permits authenticated mutations in both directions. For `readOnly`, the owner may send updates to the receiver, while the receiver is prohibited from sending local mutations back. The UI warns that receiver-side edits are not sent and may later be replaced.

`ShareAccessPolicy` is enforced at the protocol boundary for outgoing local events and incoming operations/transfers. It validates the authenticated peer’s active mapping, local and remote share IDs, role, enabled state, and access mode. Unauthorized creates, updates, moves, renames, and deletes fail with `unauthorizedOperation`; disabling/stopping a mapping rejects all further operations. Enforcement does not depend on disabled UI controls.

## User-facing errors and diagnostics

`PeerNestLANError` maps discovery, privacy, pairing, identity, authentication, protocol, encryption, invitation, authorization, and connection failures to user-friendly messages. Network and cryptographic details are retained only as development diagnostics where useful. No private key, ephemeral/session key, file content, credential, or unnecessary absolute path is logged.

## Threat model and known limitations

This milestone protects folder traffic against passive LAN observers, frame modification, replay, an unknown peer, and a previously trusted peer whose long-term identity changed. The displayed pairing code lets users detect an active man-in-the-middle when they compare both screens correctly. It does not protect a compromised Mac, a compromised login session/Keychain, malicious files that the user intentionally shares, traffic analysis, denial of service, or a user who confirms mismatched codes.

Known limitations:

- The app supports one active primary peer transport at a time in this milestone, though multiple trusted records and mappings persist.
- Pairing uses authenticated CryptoKit encryption for normal sessions rather than Network.framework TLS certificates; there is therefore no certificate lifecycle.
- Bonjour visibility depends on local-network permission, multicast support, firewall policy, and network client isolation.
- Approximate invitation size/item counts are optional and are not yet calculated.
- There is no unattended background daemon, internet relay, cloud identity, or remote access.
- Real two-Mac behavior must be verified manually; automated coverage uses state-machine tests and local loopback.

