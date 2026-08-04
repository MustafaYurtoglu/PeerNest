#!/bin/bash

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DERIVED_DATA_ROOT="${HOME}/Library/Developer/Xcode/DerivedData"
PLIST_BUDDY="/usr/libexec/PlistBuddy"
TMP_IDENTIFIERS="$(mktemp -t peernest-extension-identifiers)"
trap 'rm -f "$TMP_IDENTIFIERS"' EXIT

print_appex() {
    local appex="$1"
    local plist="$appex/Contents/Info.plist"
    local bundle_id="unavailable"
    local extension_point="unavailable"
    if [[ -f "$plist" ]]; then
        bundle_id="$($PLIST_BUDDY -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
        extension_point="$($PLIST_BUDDY -c 'Print :NSExtension:NSExtensionPointIdentifier' "$plist" 2>/dev/null || true)"
    fi
    printf '    appex: %s\n' "$appex"
    printf '      bundle identifier: %s\n' "$bundle_id"
    printf '      extension point: %s\n' "$extension_point"
    printf '%s\n' "$bundle_id" >> "$TMP_IDENTIFIERS"
}

printf 'PeerNest extension inspection\n'
printf 'Repository: %s\n\n' "$REPO_ROOT"

printf 'Built PeerNest app locations:\n'
FOUND_APP=0
if [[ -d "$DERIVED_DATA_ROOT" ]]; then
    while IFS= read -r app; do
        FOUND_APP=1
        printf '  %s\n' "$app"
        if [[ -d "$app/Contents/PlugIns" ]]; then
            while IFS= read -r appex; do
                print_appex "$appex"
            done < <(find "$app/Contents/PlugIns" -maxdepth 1 -type d -name '*.appex' -print | sort)
        fi
    done < <(find "$DERIVED_DATA_ROOT" -type d -name 'PeerNest.app' -print 2>/dev/null | sort)
fi
if [[ "$FOUND_APP" -eq 0 ]]; then
    printf '  none found in DerivedData\n'
fi

printf '\nPeerNest PlugInKit registrations:\n'
PLUGIN_OUTPUT="$(pluginkit -m -D -A -v -v -v -i com.mustafayurtoglu.PeerNest.FinderExtension 2>&1 || true)"
if [[ -n "$PLUGIN_OUTPUT" ]]; then
    printf '%s\n' "$PLUGIN_OUTPUT"
else
    printf '  none found\n'
fi

printf '\nDuplicate extension identifiers among built app bundles:\n'
DUPLICATES="$(sort "$TMP_IDENTIFIERS" | uniq -d)"
if [[ -n "$DUPLICATES" ]]; then
    printf '%s\n' "$DUPLICATES"
else
    printf '  none\n'
fi

REGISTRATION_COUNT="$(printf '%s\n' "$PLUGIN_OUTPUT" | grep -c 'com.mustafayurtoglu.PeerNest.FinderExtension' || true)"
printf '\nPlugInKit registrations with the PeerNest Finder bundle identifier: %s\n' "$REGISTRATION_COUNT"
if [[ "$REGISTRATION_COUNT" -gt 1 ]]; then
    printf '  duplicate development registrations detected\n'
else
    printf '  no duplicate registration detected\n'
fi

printf '\nPlugInKit paths that no longer exist:\n'
STALE_COUNT=0
while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if [[ ! -e "$path" ]]; then
        STALE_COUNT=$((STALE_COUNT + 1))
        printf '  %s\n' "$path"
    fi
done < <(printf '%s\n' "$PLUGIN_OUTPUT" | sed -n 's/^[[:space:]]*Path = //p')
if [[ "$STALE_COUNT" -eq 0 ]]; then
    printf '  none\n'
fi
