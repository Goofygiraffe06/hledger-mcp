param([Parameter(Mandatory=$true)][string]$Target)
$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot
Push-Location $Repo
try {
  $Binary = (cabal list-bin hledger-mcp).Trim()
} finally {
  Pop-Location
}
$Stage = Join-Path $Repo "release/hledger-mcp-$Target"
$Archive = Join-Path $Repo "release/hledger-mcp-$Target.zip"
Remove-Item $Stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item $Stage -ItemType Directory -Force | Out-Null
Copy-Item $Binary (Join-Path $Stage "hledger-mcp.exe")
$GhcRoot = Split-Path -Parent (ghc --print-libdir)
Get-ChildItem $GhcRoot -Recurse -File -Include "libgmp*.dll", "libffi*.dll", "libiconv*.dll" |
  ForEach-Object { Copy-Item $_.FullName $Stage -Force }
Copy-Item (Join-Path $Repo "LICENSE") $Stage
Copy-Item (Join-Path $Repo "hledger-mcp/README.md") (Join-Path $Stage "README.md")
Remove-Item $Archive -Force -ErrorAction SilentlyContinue
Compress-Archive -Path $Stage -DestinationPath $Archive
Write-Output $Archive
