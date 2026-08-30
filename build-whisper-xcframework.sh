#!/bin/bash
# Build only the existing pinned Whisper dependency for iPhone/iPad.
# The result contains all ggml libraries and the Clang module map.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd -P)"
cd "$ROOT"
PIN="13d92d08ae26031545921243256aaaf0ee057943"
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "macOS and Xcode are required; no iOS build was performed." >&2
    exit 1
fi
for tool in git cmake xcodebuild xcrun libtool; do
    command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
git submodule update --init --depth 1 -- whisper.cpp
if [[ "$(git -C whisper.cpp rev-parse HEAD)" != "$PIN" ]]; then
    echo "Whisper revision differs from the audited pin; refusing to build." >&2
    exit 1
fi
if [[ -n "$(git -C whisper.cpp status --porcelain --untracked-files=no)" ]]; then
    echo "Whisper has tracked modifications; review them before building." >&2
    exit 1
fi
BUILD="$ROOT/.build/whisper"
OUTPUT="$BUILD/whisper.xcframework"
if [[ -e "$OUTPUT" ]]; then
    echo "Existing framework preserved at $OUTPUT"
    echo "Use a fresh clone or explicitly archive that generated output before rebuilding."
    exit 1
fi
mkdir -p "$BUILD/headers"
cp "$ROOT/whisper.cpp/include/whisper.h" "$BUILD/headers/"
cp "$ROOT/whisper.cpp/ggml/include/"*.h "$BUILD/headers/"
cp "$ROOT/whisper.cpp/LICENSE" "$BUILD/WHISPER-LICENSE"
cat > "$BUILD/headers/module.modulemap" <<'MODULE'
module whisper {
    header "whisper.h"
    export *
    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"
}
MODULE

build_slice() {
    local sdk="$1"
    local architectures="$2"
    local destination="$BUILD/$sdk"
    cmake -S "$ROOT/whisper.cpp" -B "$destination" -G Xcode \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$sdk" \
        -DCMAKE_OSX_ARCHITECTURES="$architectures" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=17.6 \
        -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
        -DBUILD_SHARED_LIBS=OFF \
        -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_EXAMPLES=OFF \
        -DWHISPER_BUILD_SERVER=OFF \
        -DWHISPER_COREML=OFF \
        -DGGML_METAL=ON \
        -DGGML_METAL_EMBED_LIBRARY=ON \
        -DGGML_BLAS=ON \
        -DGGML_OPENMP=OFF \
        -DGGML_NATIVE=OFF
    cmake --build "$destination" --config Release -- -quiet
    local libraries=()
    while IFS= read -r library; do
        libraries+=("$library")
    done < <(find "$destination" -type f -path "*/Release-$sdk/*" -name 'lib*.a')
    if [[ ${#libraries[@]} -lt 4 ]]; then
        echo "Expected whisper and ggml static libraries were not all produced." >&2
        exit 1
    fi
    libtool -static -o "$BUILD/whisper-$sdk.a" "${libraries[@]}"
}

build_slice iphoneos arm64
build_slice iphonesimulator "arm64;x86_64"
xcodebuild -create-xcframework \
    -library "$BUILD/whisper-iphoneos.a" -headers "$BUILD/headers" \
    -library "$BUILD/whisper-iphonesimulator.a" -headers "$BUILD/headers" \
    -output "$OUTPUT"
echo "Built $OUTPUT. This is not an app build or a physical-device test."
