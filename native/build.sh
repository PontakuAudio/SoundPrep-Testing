#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ ! -f native/analysis.cpp ] || [ ! -f native/zwicker.cpp ] || [ ! -f native/lufs_meter.cpp ]; then
  echo 'The analysis engine source is not in the public checkout. Use the prebuilt release helper; see docs/source-distribution.md.' >&2
  exit 1
fi
python3 tools/generate_native_contract.py --check
mkdir -p build
clang++ -std=c++17 -Wall -Wextra -Werror -O2 native/test_transport.cpp -o build/test_transport
build/test_transport
clang++ -std=c++17 -Wall -Wextra -Werror -O2 native/test_preview.cpp -o build/test_preview
build/test_preview
clang++ -std=c++17 -Wall -Wextra -Werror -O2 native/test_cursor.cpp -o build/test_cursor
build/test_cursor
clang++ -std=c++17 -Wall -Wextra -Werror -O2 native/test_wave.cpp -o build/test_wave
build/test_wave
clang++ -std=c++17 -Wall -Wextra -Werror -O2 -ffp-contract=off native/test_zwicker.cpp -o build/test_zwicker
build/test_zwicker
clang++ -std=c++17 -Wall -Wextra -Werror -O2 -ffp-contract=off native/test_lufs_meter.cpp native/lufs_meter.cpp -o build/test_lufs_meter
build/test_lufs_meter
clang++ -std=c++17 -Wall -Wextra -Werror -O2 -ffp-contract=off native/test_analysis.cpp native/zwicker.cpp native/lufs_meter.cpp -o build/test_analysis
build/test_analysis
clang++ -std=c++17 -Wall -Wextra -Werror -O2 -fobjc-arc native/test_search.mm -framework Cocoa -o build/test_search
build/test_search
clang++ -std=c++17 -Wall -Wextra -Werror -O2 -fobjc-arc native/test_bar.mm -framework Cocoa -o build/test_bar
build/test_bar
clang++ -std=c++17 -Wall -Wextra -Werror -O2 -ffp-contract=off -dynamiclib -fvisibility=hidden \
  -Wl,-exported_symbol,_ReaperPluginEntry \
  -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -DAM_EMBEDDED_BAR \
  -fobjc-arc native/transport.cpp native/bar.mm native/drop.mm native/prepare.mm native/preview.cpp native/wave.cpp native/cursor.cpp native/search.mm native/analysis.cpp native/zwicker.cpp native/lufs_meter.cpp -framework Cocoa \
  -o build/reaper_audition_macro.dylib
# Preserve the exported REAPER entry point; omit local/debug symbols from releases.
strip -S -x build/reaper_audition_macro.dylib
codesign --force --sign - build/reaper_audition_macro.dylib
clang++ -std=c++17 -Wall -Wextra -Werror -O2 -dynamiclib -fvisibility=hidden \
  -Wl,-exported_symbol,_ReaperPluginEntry \
  -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -fobjc-arc \
  native/worker.mm -framework Cocoa -o build/reaper_audition_macro_worker.dylib
strip -S -x build/reaper_audition_macro_worker.dylib
codesign --force --sign - build/reaper_audition_macro_worker.dylib
