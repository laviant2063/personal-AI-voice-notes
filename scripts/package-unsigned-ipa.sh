#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <path-to-app> <output.ipa>" >&2
    exit 64
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "macOS ditto is required to preserve an iOS app bundle." >&2
    exit 1
fi
for tool in /usr/bin/ditto /usr/bin/unzip; do
    [[ -x "$tool" ]] || { echo "Missing required tool: $tool" >&2; exit 1; }
done

app="$1"
output="$2"
if [[ ! -d "$app" || "$app" != *.app || ! -f "$app/Info.plist" ]]; then
    echo "Input is not a built iOS .app bundle." >&2
    exit 1
fi
if [[ "$output" != *.ipa ]]; then
    echo "Output must use the .ipa extension." >&2
    exit 1
fi
if [[ -e "$output" ]]; then
    echo "Existing IPA preserved; refusing to overwrite: $output" >&2
    exit 1
fi

output_parent="$(dirname "$output")"
mkdir -p "$output_parent"
output_parent="$(cd "$output_parent" && pwd -P)"
output="$output_parent/$(basename "$output")"
temp_root="$(printenv TMPDIR || true)"
[[ -n "$temp_root" ]] || temp_root=/tmp
temp_root="$(printf %s "$temp_root" | sed 's:/*$::')"
stage="$(mktemp -d "$temp_root/voice-notes-ipa.XXXXXX")"
cleanup() {
    case "$stage" in
        "$temp_root"/voice-notes-ipa.*) rm -rf "$stage" ;;
        *) echo "Unexpected temporary path preserved: $stage" >&2 ;;
    esac
}
trap cleanup EXIT

mkdir -p "$stage/Payload"
/usr/bin/ditto "$app" "$stage/Payload/$(basename "$app")"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$stage/Payload" "$output"
/usr/bin/unzip -tq "$output"
expected="Payload/$(basename "$app")/Info.plist"
if ! /usr/bin/unzip -Z1 "$output" | grep -Fxq "$expected"; then
    echo "IPA is missing $expected" >&2
    exit 1
fi
echo "$output"
