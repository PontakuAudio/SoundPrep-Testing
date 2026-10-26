param([string]$ResourcePath = (Join-Path $env:APPDATA 'REAPER'))
$ErrorActionPreference = 'Stop'
# Never replace a DLL loaded by any REAPER process, including portable installs.
if (Get-Process -Name reaper,reaper_host32,reaper_host64 -ErrorAction SilentlyContinue) {
  throw 'Save your work and quit all REAPER instances before updating the helper.'
}
if (-not (Test-Path -LiteralPath (Join-Path $ResourcePath 'reaper.ini'))) {
  throw 'REAPER resource directory not found. Pass -ResourcePath for a portable installation.'
}
$Root = Split-Path $PSScriptRoot -Parent
$Source = Join-Path $Root 'build/reaper_audition_macro.dll'
if (-not (Test-Path -LiteralPath $Source)) { throw 'Download a Windows x64 package or run native/build-windows.ps1 first.' }
# Reject another architecture or a file that is not a PE image before installation.
$Bytes = [IO.File]::ReadAllBytes($Source)
if ($Bytes.Length -lt 256 -or $Bytes[0] -ne 0x4D -or $Bytes[1] -ne 0x5A) { throw 'Not a Windows DLL' }
$Offset = [BitConverter]::ToInt32($Bytes, 0x3C)
if ($Offset -lt 0 -or $Offset + 6 -gt $Bytes.Length -or [BitConverter]::ToUInt32($Bytes, $Offset) -ne 0x4550 -or [BitConverter]::ToUInt16($Bytes, $Offset + 4) -ne 0x8664) { throw 'The helper must be a Windows x64 PE image' }
$Directory = Join-Path $ResourcePath 'UserPlugins'
New-Item -ItemType Directory -Path $Directory -Force | Out-Null
$Target = Join-Path $Directory 'reaper_audition_macro.dll'
$Temp = "$Target.new"
Copy-Item -LiteralPath $Source -Destination $Temp -Force
if (Test-Path -LiteralPath $Target) {
  $Backup = "$Target.backup"
  [IO.File]::Replace($Temp, $Target, $Backup, $true)
} else { [IO.File]::Move($Temp, $Target) }
Write-Output "Installed: $Target"
Write-Output 'Start REAPER x64, then run SoundPrep.lua.'
