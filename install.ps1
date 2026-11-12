param(
  [string]$Repository = "Goofygiraffe06/hledger-mcp",
  [string]$InstallRoot = "$env:LOCALAPPDATA\hledger-mcp"
)
$ErrorActionPreference = "Stop"
$asset = "hledger-mcp-windows-x86_64.zip"
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("hledger-mcp-" + [guid]::NewGuid())
New-Item $temporary -ItemType Directory | Out-Null
try {
  $archive = Join-Path $temporary $asset
  Invoke-WebRequest "https://github.com/$Repository/releases/latest/download/$asset" -OutFile $archive
  Expand-Archive $archive -DestinationPath $temporary
  New-Item $InstallRoot -ItemType Directory -Force | Out-Null
  Copy-Item (Join-Path $temporary "hledger-mcp-windows-x86_64\*") $InstallRoot -Recurse -Force
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if (($userPath -split ';') -notcontains $InstallRoot) {
    [Environment]::SetEnvironmentVariable("Path", ($userPath.TrimEnd(';') + ";" + $InstallRoot), "User")
  }
  & (Join-Path $InstallRoot "hledger-mcp.exe") --init | Out-Null
  Write-Output "Installed hledger-mcp to $InstallRoot"
  & (Join-Path $InstallRoot "hledger-mcp.exe") --show-paths
} finally {
  Remove-Item $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
