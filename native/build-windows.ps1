param([string]$Configuration = 'Release', [switch]$LuaTests)
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
cmake -S $Root -B "$Root/build/windows" -A x64 "-DAM_TEST_LUA=$($LuaTests.IsPresent)"
if ($LASTEXITCODE) { throw 'CMake configure failed. Install Visual Studio 2022 C++ Build Tools and CMake.' }
cmake --build "$Root/build/windows" --config $Configuration --parallel
if ($LASTEXITCODE) { throw 'Windows build failed' }
ctest --test-dir "$Root/build/windows" -C $Configuration --output-on-failure
if ($LASTEXITCODE) {
  throw "Windows tests failed. Compiled DLLs remain in build/windows/$Configuration; build/*.dll and REAPER's installed helper have NOT been updated. See the CTest failures above."
}
foreach ($Name in @('reaper_audition_macro.dll','reaper_audition_macro_worker.dll')) {
  Copy-Item -LiteralPath "$Root/build/windows/$Configuration/$Name" -Destination "$Root/build/$Name" -Force
}
Write-Output 'Windows x64 helpers built and tested. Run tools/install_native.ps1 with REAPER closed.'
