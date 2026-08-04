# PeerNest two-Mac manual test

Use disposable folders and files for this test. A successful automated local-loopback test is not a substitute for this real two-Mac procedure.

## Preparation

1. Build and install the same PeerNest version on Mac A and Mac B.
2. Confirm both Macs are connected to the same Wi-Fi or Ethernet LAN. Disable VPN routing temporarily if it isolates local traffic.
3. Launch PeerNest on both Macs.
4. When macOS asks, approve local-network access for PeerNest on both Macs.
5. In PeerNest, verify each Mac appears under Nearby Devices on the other Mac. Check that the displayed interface is sensible and that no fake peers appear.

## Pair and establish trust

6. On Mac A, select Mac B under Nearby and click Pair.
7. On Mac B, inspect the incoming request and click Approve only if the name is Mac A.
8. Compare the six-digit verification code on both Macs character by character.
9. Click Confirm Codes Match on Mac A and Mac B.
10. Verify each device moves to Trusted, its fingerprint is visible, and the connection status becomes an authenticated encrypted connection.
11. Quit and reopen both apps once. Verify the trusted entries persist and the lower peer-ID owner automatically reconnects when both are visible.

## Read/write invitation and synchronization

12. On Mac A, add a new disposable shared test folder such as `PeerNest Test A`.
13. Open Mac B’s trusted-device detail on Mac A, choose that folder, select Read & Write, and send the invitation.
14. On Mac B, verify the incoming invitation shows Mac A, the folder display name, Read & Write, and no Mac A absolute path.
15. Click Choose Destination and Accept, then choose or create a disposable destination folder on Mac B.
16. Verify an accepted mapping appears on both Macs. Run initial synchronization from the active share controls.
17. On Mac A, create nested folders and files. Verify they appear recursively on Mac B.
18. On Mac B, edit a file, create another nested file, rename and move items, and delete a disposable item. Verify every operation appears on Mac A.
19. Repeat create, edit, rename, move, and delete operations from Mac A and verify Mac B. Confirm no echo loop or endlessly duplicated conflict file appears.

## Reconnect and persistence

20. Disconnect and reconnect Wi-Fi, or unplug/reconnect Ethernet, on one Mac.
21. Verify the trusted peer changes offline/online and reconnects automatically with bounded delay.
22. Quit and reopen both applications.
23. Verify the trust fingerprint, auto-connect preference, shared folders, accepted mapping, and folder monitoring persist. Verify synchronization resumes without a new invitation.

## Read-only enforcement

24. Stop the disposable read/write mapping; confirm no files are deleted.
25. Send a second invitation from Mac A to Mac B using Read Only and accept it into a different disposable destination on Mac B.
26. Verify Mac A updates reach Mac B.
27. Modify or delete a file locally on Mac B. Verify PeerNest reports that the reverse mutation is unauthorized and does not send it to Mac A. Owner updates may replace receiver-local edits.

## Revocation

28. On Mac A, choose Forget Device for Mac B and confirm the warning: “PeerNest will stop trusting this device. Your local files will not be deleted.”
29. Verify the active connection closes, auto-connect stops, and associated mappings are disabled.
30. Confirm files on both Macs remain untouched.
31. Attempt normal reconnection from Mac B. Verify it is rejected and cannot synchronize.
32. Verify a new explicit pairing with matching-code confirmation is required before either device can trust the other again.

## Identity-change check (advanced)

On a disposable test installation only, remove PeerNest’s `curve25519-signing-private-key-v1` Keychain item on one Mac and relaunch it. The other Mac must mark that trusted record as Identity Changed, block automatic/normal connection, and require explicit re-pairing. Do not perform this on an identity you intend to keep.

## Troubleshooting

- System Settings → Privacy & Security → Local Network: ensure PeerNest is enabled on both Macs. Toggle it off/on and relaunch if the prompt was previously denied.
- System Settings → Network → Firewall → Options: allow incoming connections for PeerNest. Do not disable the firewall permanently.
- Ensure the router/access point does not enable client/AP isolation, guest-network isolation, or multicast filtering.
- Keep both Macs on the same non-guest VLAN/subnet. Some enterprise Wi-Fi networks intentionally suppress Bonjour/mDNS.
- Disconnect VPN software that captures or blocks local routes/multicast, then relaunch PeerNest.
- Confirm both apps advertise `_peernest._tcp` and use the same protocol version/build.
- If a peer is shown offline after a network change, wait through the bounded reconnect delay, then use manual Connect.
- If Identity Changed appears unexpectedly, compare fingerprints and investigate reinstall/Keychain changes. Never bypass the warning; pair again only after verifying the physical device.
- The DEBUG “Localhost Synchronization Prototype” uses explicit host/port and plaintext for automated compatibility testing. Do not use it as evidence that production LAN encryption works.
