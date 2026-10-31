param([string]$Destination = $(if ($env:WATCHROOM_PLUGINS) { $env:WATCHROOM_PLUGINS } else { Join-Path $env:LOCALAPPDATA 'Watchroom/plugins' }))
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'plugins'
foreach ($folder in @('sparrow-runtime', 'sparrow-subsplease', 'sparrow-eztv', 'sparrow-tokyotoshokan', 'sparrow-therarbg')) {
    $target = Join-Path $Destination $folder
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    # Copy shipped files only. Preserve settings.json and other user files on reinstall.
    Get-ChildItem -LiteralPath (Join-Path $source $folder) -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $target $_.Name) -Force
    }
}
Write-Output "Installed SubsPlease, EZTV, TokyoToshokan and TheRARBG in $Destination"
