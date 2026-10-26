#!/bin/sh
# Replace only after REAPER exits. A loaded dylib must never be overwritten.
set -eu
cd "$(dirname "$0")/.."
process_list=$(ps -axo comm=) || {
  echo 'Cannot inspect running processes; refusing to replace the native helper.' >&2
  exit 1
}
if printf '%s\n' "$process_list" | /usr/bin/grep -Eq '(^|/)REAPER$'; then
  echo 'REAPER is running. Save your work and quit every REAPER instance, then run this installer again.' >&2
  exit 1
fi
source_file=build/reaper_audition_macro.dylib
if [ ! -f "$source_file" ]; then
  echo 'Build the helper first: sh native/build.sh' >&2
  exit 1
fi
resource_dir="${1:-$HOME/Library/Application Support/REAPER}"
target_dir="$resource_dir/UserPlugins"
if [ ! -f "$resource_dir/reaper.ini" ]; then
  echo 'REAPER resource directory not found; pass its path as the first argument.' >&2
  exit 1
fi
codesign --verify "$source_file"
mkdir -p "$target_dir"
# Atomic installation, with a recoverable copy of the previous helper.
if [ -f "$target_dir/reaper_audition_macro.dylib" ]; then
  cp "$target_dir/reaper_audition_macro.dylib" "$target_dir/reaper_audition_macro.dylib.backup"
fi
cp "$source_file" "$target_dir/reaper_audition_macro.dylib.new"
mv "$target_dir/reaper_audition_macro.dylib.new" "$target_dir/reaper_audition_macro.dylib"
echo "Installed: $target_dir/reaper_audition_macro.dylib"
echo 'Start REAPER, then run SoundPrep.lua.'
