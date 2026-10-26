#!/bin/sh
# Run native fixtures with assertions and fatal sanitizer diagnostics.
# This does not install helpers or start REAPER.
set -eu
cd "$(dirname "$0")/.."
sanitizer=${SANITIZER:-address,undefined,float-cast-overflow}
case "$sanitizer" in
  address,undefined,float-cast-overflow|thread) ;;
  *) echo 'Use SANITIZER=thread or the default ASan/UBSan combination' >&2; exit 2 ;;
esac
directory="build/sanitizers/$sanitizer"
mkdir -p "$directory"
export UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1
export TSAN_OPTIONS=halt_on_error=1
for test in transport preview cursor wave; do
  clang++ -std=c++17 -Wall -Wextra -Werror -O1 -g -fno-omit-frame-pointer \
    -fsanitize="$sanitizer" -fno-sanitize-recover=all \
    "native/test_$test.cpp" -o "$directory/test_$test"
  "$directory/test_$test"
done
for test in zwicker lufs_meter analysis; do
  case "$test" in
    zwicker) sources="native/test_zwicker.cpp" ;;
    lufs_meter) sources="native/test_lufs_meter.cpp native/lufs_meter.cpp" ;;
    analysis) sources="native/test_analysis.cpp native/zwicker.cpp native/lufs_meter.cpp" ;;
  esac
  clang++ -std=c++17 -Wall -Wextra -Werror -O1 -g -fno-omit-frame-pointer -ffp-contract=off \
    -fsanitize="$sanitizer" -fno-sanitize-recover=all \
    $sources -o "$directory/test_$test"
  "$directory/test_$test"
done
# Cocoa fixtures exercise real controls; the thread suite is limited to the
# common native fixtures, including concurrent audio/control operations.
if [ "$sanitizer" != thread ]; then
  for test in search bar; do
    clang++ -std=c++17 -Wall -Wextra -Werror -O1 -g -fno-omit-frame-pointer \
      -fsanitize="$sanitizer" -fno-sanitize-recover=all -fobjc-arc \
      "native/test_$test.mm" -framework Cocoa -o "$directory/test_$test"
    "$directory/test_$test"
  done
fi
