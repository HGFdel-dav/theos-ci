# RoutePilot

RoutePilot is a RootHide-oriented iOS tweak project for maintaining a per-app direct-route selection list.

## Device target

- iPhone 12 / A14 / arm64e
- iOS 15.5
- RootHide, built with `roothide/theos` and iPhoneOS 15.5 SDK
- Package ID: `com.niubiprass.routepilot`

## Implemented in this scaffold

- Theos tweak and PreferenceBundle project structure.
- RootHide/rootless path helpers from the merged project template.
- RoutePilot-branded PreferenceLoader entry and icon.
- AltList multi-selection UI for installed user apps; selected bundle identifiers are stored in RoutePilot's preference domain as `directBundleIDs`.
- `doctor.py` static project validation.

## Not implemented

This build does not alter packet routing. The app list is policy data only. The RoutePilot toggle must not be described as making selected apps bypass an active VPN until a backend adapter has been implemented and traffic-tested.

A packet-tunnel provider ordinarily routes IP packets using tunnel routes and does not receive a generic process-to-route policy from an unrelated tweak. Apple's managed per-app VPN facility is a separate deployment model and does not transparently control arbitrary consumer VPN clients. Therefore a working product needs a reviewed adapter for each VPN client/provider, or an OS-level per-app VPN configuration supported by the device's management setup.

## Adapter contract

Each client adapter must, before being marked connected:

1. Identify the active provider and exact app/extension version.
2. Locate a documented or reverse-engineered configuration interface with verified read/write semantics.
3. Add direct rules for the selected bundle identifiers while preserving all other rules and the current VPN's default route.
4. Apply changes through the provider's supported reload path, without modifying unrelated profile state.
5. Report failures and restore the saved configuration on disable/uninstall.
6. Pass traffic tests for a selected app and a non-selected app, including IPv4, IPv6, DNS, reconnect and VPN-switch cases.

Initial candidates are Quantumult X, Loon, Shadowrocket and Shanlian VPN. No adapter is claimed implemented yet.

## Validation

`python3 /var/minis/skills/ios-roothide-tweak-forge/scripts/doctor.py .` checks project structure and plist identities only. It does not compile or validate routing. Build and release must use the existing `theos-ci` workflow after an adapter is implemented; keep the iPhoneOS 15.5 SDK and RootHide arm64e target. Preserve ldid/code-signature, DEB payload, package metadata, SHA256, and on-device load/traffic verification gates.
