$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'UTAU-Batch-Render.ps1'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "見つかりません: $scriptPath"
}

$sendTo = [Environment]::GetFolderPath('SendTo')
$shortcutPath = Join-Path $sendTo 'UTAU 一括レンダリング.lnk'
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershell
$shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '"'
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.Description = '複数のUSTを本家UTAUで順番にWAV化'
$shortcut.Save()

Write-Output "登録しました: $shortcutPath"
