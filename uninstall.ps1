$ErrorActionPreference = 'Stop'

$shortcutPath = Join-Path ([Environment]::GetFolderPath('SendTo')) 'UTAU 一括レンダリング.lnk'
if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
    Remove-Item -LiteralPath $shortcutPath
    Write-Output "解除しました: $shortcutPath"
}
else {
    Write-Output '登録済みのショートカットはありません。'
}
