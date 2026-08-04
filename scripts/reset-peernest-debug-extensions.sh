#!/bin/bash

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DERIVED_DATA_ROOT="${HOME}/Library/Developer/Xcode/DerivedData"
EXECUTE=0

case "${1:-}" in
    "") ;;
    --execute) EXECUTE=1 ;;
    --help|-h)
        printf 'Usage: %s [--execute]\n' "$0"
        printf 'Dry-run is the default. --execute unregisters repository development extensions and removes only validated temporary build artifacts.\n'
        exit 0
        ;;
    *)
        printf 'Unknown argument: %s\n' "$1" >&2
        exit 2
        ;;
esac

printf 'PeerNest development extension reset\n'
printf 'Repository: %s\n' "$REPO_ROOT"
if [[ "$EXECUTE" -eq 0 ]]; then
    printf 'Mode: dry-run (no changes will be made)\n'
else
    printf 'Mode: execute\n'
fi

is_expected_temporary_appex() {
    local appex="$1"
    local plist="$appex/Contents/Info.plist"
    case "$appex" in
        /private/tmp/PeerNest*/Build/Products/Debug/PeerNest.app/Contents/PlugIns/PeerNestFinderExtension.appex|\
        /private/tmp/PeerNest*/Build/Products/Release/PeerNest.app/Contents/PlugIns/PeerNestFinderExtension.appex) ;;
        *) return 1 ;;
    esac
    [[ -f "$plist" ]] || return 1
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)" == "com.mustafayurtoglu.PeerNest.FinderExtension" ]] || return 1
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$plist" 2>/dev/null || true)" == "com.apple.FinderSync" ]] || return 1
}

FOUND=0
PLUGIN_OUTPUT="$(pluginkit -m -D -A -v -v -v -i com.mustafayurtoglu.PeerNest.FinderExtension 2>&1 || true)"
while IFS= read -r appex; do
    [[ -n "$appex" ]] || continue
    if ! is_expected_temporary_appex "$appex"; then
        continue
    fi
    FOUND=1
    printf 'Would unregister temporary development extension: %s\n' "$appex"
    if [[ "$EXECUTE" -eq 1 ]]; then
        pluginkit -r "$appex" || true
    fi

    build_directory="${appex%%/Build/Products/*}/Build"
    case "$build_directory" in
        /private/tmp/PeerNest*/Build)
            printf 'Would remove temporary build artifacts: %s\n' "$build_directory"
            if [[ "$EXECUTE" -eq 1 ]]; then
                rm -rf -- "$build_directory"
            fi
            ;;
    esac
done < <(printf '%s\n' "$PLUGIN_OUTPUT" | sed -n 's/^[[:space:]]*Path = //p' | sort -u)

if [[ -d "$DERIVED_DATA_ROOT" ]]; then
    while IFS= read -r derived_dir; do
        info_plist="$derived_dir/info.plist"
        [[ -f "$info_plist" ]] || continue
        workspace_path="$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$info_plist" 2>/dev/null || true)"
        case "$workspace_path" in
            "$REPO_ROOT"/*) ;;
            *) continue ;;
        esac
        case "$derived_dir" in
            "$DERIVED_DATA_ROOT"/PeerNest-*) ;;
            *) continue ;;
        esac

        FOUND=1
        while IFS= read -r appex; do
            printf 'Would unregister: %s\n' "$appex"
            if [[ "$EXECUTE" -eq 1 ]]; then
                pluginkit -r "$appex" || true
            fi
        done < <(find "$derived_dir" -type d -path '*/PeerNest.app/Contents/PlugIns/*.appex' -print 2>/dev/null | sort -u)

        printf 'Would remove repository DerivedData: %s\n' "$derived_dir"
        if [[ "$EXECUTE" -eq 1 ]]; then
            rm -rf -- "$derived_dir"
        fi
    done < <(find "$DERIVED_DATA_ROOT" -maxdepth 1 -type d -name 'PeerNest-*' -print | sort)
fi

if [[ "$FOUND" -eq 0 ]]; then
    printf 'No DerivedData associated with this PeerNest repository was found.\n'
fi

if [[ "$EXECUTE" -eq 0 ]]; then
    printf '\nNothing changed. Re-run with --execute only if the printed targets are correct.\n'
else
    printf '\nDevelopment cleanup finished. No user documents or installed production apps were targeted.\n'
fi
