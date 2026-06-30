# Freeze the EVS sidecar into a single evs_sidecar.exe, then emit its sha256 +
# size into ../dist/components.json so the app can download it on demand.
#
#   cd test1\sidecar
#   .\build_exe.ps1                       # build + update components.json
#   .\build_exe.ps1 -ComponentVersion 2   # bump the component version
#
# Needs Python 3.12 (faster-whisper / ctranslate2 / webrtcvad lack 3.14 wheels).
# Reuses .venv if present; otherwise creates it with uv (preferred) or py -3.12.
# The frozen exe is NOT bundled in the installer anymore — it's a downloaded
# component (see ComponentManager + dist/components.json).

param(
  [string]$ComponentVersion = "1",
  # Where the built exe will be hosted (a GitHub release asset).
  [string]$Url = "https://github.com/kekw2077/mirai/releases/download/desktop-components/evs_sidecar.exe"
)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here
$py = Join-Path $here ".venv\Scripts\python.exe"

if (-not (Test-Path $py)) {
  $uv = Get-Command uv -ErrorAction SilentlyContinue
  if ($uv) { Write-Host "Creating venv (uv, Python 3.12)..."; uv venv --python 3.12 .venv }
  else { Write-Host "Creating venv (py -3.12)..."; py -3.12 -m venv .venv }
}

# Install deps (uv preferred). uv writes progress to stderr — that's fine, don't
# treat it as fatal (no ErrorActionPreference=Stop around native commands).
$uv = Get-Command uv -ErrorAction SilentlyContinue
if ($uv) {
  $env:VIRTUAL_ENV = (Resolve-Path ".venv").Path
  uv pip install -r requirements.txt pyinstaller
} else {
  & $py -m pip install --upgrade pip
  & $py -m pip install -r requirements.txt pyinstaller
}

# --collect-all pulls each library's data files, dynamic libs and hidden
# submodules (PyAV/ctranslate2 DLLs, sounddevice's portaudio, pyttsx3's sapi5
# driver). The Whisper model itself is NOT bundled — faster-whisper downloads it
# on first use into the HF cache (HF_HOME, set by the app to its data folder).
& $py -m PyInstaller --onefile --noconfirm --name evs_sidecar `
  --collect-all faster_whisper `
  --collect-all ctranslate2 `
  --collect-all onnxruntime `
  --collect-all av `
  --collect-all webrtcvad `
  --collect-all sounddevice `
  --collect-all pyttsx3 `
  --hidden-import comtypes `
  main.py

$exe = Join-Path $here "dist\evs_sidecar.exe"
if (-not (Test-Path $exe)) { Write-Error "PyInstaller did not produce $exe"; exit 1 }

# Update the sidecar entry in ../dist/components.json (merge, don't clobber
# other components like tts-clone).
$sha = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLower()
$size = (Get-Item $exe).Length
$manifestPath = Join-Path $here "..\dist\components.json"
if (Test-Path $manifestPath) {
  $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
} else {
  $manifest = [pscustomobject]@{ components = [pscustomobject]@{} }
}
if (-not $manifest.components) {
  $manifest | Add-Member -NotePropertyName components -NotePropertyValue ([pscustomobject]@{}) -Force
}
$entry = [pscustomobject]@{
  file    = "evs_sidecar.exe"
  version = $ComponentVersion
  url     = $Url
  sha256  = $sha
  size    = $size
}
$manifest.components | Add-Member -NotePropertyName sidecar -NotePropertyValue $entry -Force
$manifest | ConvertTo-Json -Depth 6 | Set-Content $manifestPath -Encoding utf8

Write-Host "evs_sidecar.exe  sha256=$sha  size=$size"
Write-Host "Updated $manifestPath (sidecar v$ComponentVersion)."
Write-Host "Next: upload dist\evs_sidecar.exe to the 'desktop-components' release, then commit components.json."
