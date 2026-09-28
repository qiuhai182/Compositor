#!/usr/bin/env bash
# Builds the cross-platform core package (CompositorCore, see docs/cross-platform.md)
# on Linux, or on macOS where the app itself still needs Xcode.
# Everything stays under output/: SwiftPM intermediates in output/.build, SwiftPM's
# cache in output/.cache, copied build products in output/bin, logs next to them.
#
# Usage:
#   ./build.sh            build release (the default)
#   ./build.sh debug      build debug
#   ./build.sh test       also build and run the test suite
set -euo pipefail

cd "$(dirname "$0")"

output_dir="output"
scratch_dir="$output_dir/.build"
cache_dir="$output_dir/.cache"
bin_dir="$output_dir/bin"
build_log="$output_dir/build.log"
test_log="$output_dir/test.log"

config="release"
run_tests=false
for arg in "$@"; do
    case "$arg" in
        release | debug) config="$arg" ;;
        test) run_tests=true ;;
        *) echo "error: unknown argument '$arg' (expected release, debug or test)" >&2; exit 1 ;;
    esac
done

command -v swift >/dev/null 2>&1 || {
    echo "error: swift is not in PATH - install it from https://www.swift.org/install/" >&2
    exit 1
}

mkdir -p "$scratch_dir" "$cache_dir" "$bin_dir"

swift --version | tee "$build_log"

swift_args=(-c "$config" --scratch-path "$scratch_dir" --cache-path "$cache_dir")

echo "Building CompositorCore ($config), intermediates in $scratch_dir"
swift build "${swift_args[@]}" 2>&1 | tee -a "$build_log"

bin_path="$(swift build "${swift_args[@]}" --show-bin-path)"
if [ ! -d "$bin_path" ]; then
    echo "error: expected build products in $bin_path but it does not exist" >&2
    exit 1
fi
echo "Copying build products from $bin_path to $bin_dir"
shopt -s nullglob
for artifact in "$bin_path"/*.a "$bin_path"/*.so "$bin_path"/*.so.* "$bin_path"/*.exe "$bin_path"/*.dll; do
    echo "  $artifact"
    cp -f "$artifact" "$bin_dir/"
done
if [ -d "$bin_path/Modules" ]; then
    mkdir -p "$bin_dir/Modules"
    cp -f "$bin_path/Modules/"* "$bin_dir/Modules/"
fi

if [ "$run_tests" = true ]; then
    echo "Running tests, log in $test_log"
    swift test "${swift_args[@]}" 2>&1 | tee "$test_log"
fi

echo "Done. Build products are in $bin_dir."
