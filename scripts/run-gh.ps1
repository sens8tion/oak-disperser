param(
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$GhArgs
)

$envFile = Join-Path -Path $PSScriptRoot -ChildPath '..\.env.github'
if (-not (Test-Path -Path $envFile)) {
  Write-Error "Missing .env.github. Copy .env.github.template and add GH_TOKEN value." -ErrorAction Stop
}

$tokenLine = Get-Content -Path $envFile |
  Where-Object { $_ -notmatch '^\s*#' -and $_.Trim().Length -gt 0 } |
  Where-Object { $_ -match '^GH_TOKEN\s*=\s*(.+)$' } |
  Select-Object -First 1

if (-not $tokenLine) {
  Write-Error "GH_TOKEN not found in .env.github" -ErrorAction Stop
}

$token = $tokenLine -replace '^GH_TOKEN\s*=\s*', ''

$ghCommand = Get-Command gh -ErrorAction SilentlyContinue
$ghExe = if ($ghCommand) { $ghCommand.Source } else { 'C:\\Program Files\\GitHub CLI\\gh.exe' }

if (-not (Test-Path -Path $ghExe)) {
  Write-Error "GitHub CLI executable not found." -ErrorAction Stop
}

$env:GH_TOKEN = $token
$env:GITHUB_TOKEN = $token

if (-not $GhArgs -or $GhArgs.Count -eq 0) {
  & $ghExe auth status
} else {
  & $ghExe @GhArgs
}