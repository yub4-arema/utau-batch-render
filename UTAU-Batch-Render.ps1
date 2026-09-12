[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $InputPaths,

    [switch] $SelfTest,

    [switch] $Worker,

    [int] $RenderTimeoutSeconds = 900,

    [string] $VoiceBankPath
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

if (-not ('UtauBatchRenderNative' -as [type])) {
    Add-Type @"
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;

public static class UtauBatchRenderNative
{
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetMenu(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetSubMenu(IntPtr hMenu, int nPos);

    [DllImport("user32.dll")]
    public static extern int GetMenuItemCount(IntPtr hMenu);

    [DllImport("user32.dll")]
    public static extern uint GetMenuItemID(IntPtr hMenu, int nPos);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetMenuString(IntPtr hMenu, uint uIDItem, StringBuilder lpString, int nMaxCount, uint uFlag);

    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder text, int maxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, string lParam);

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    public static string WindowText(IntPtr hWnd)
    {
        var text = new StringBuilder(512);
        GetWindowText(hWnd, text, text.Capacity);
        return text.ToString();
    }

    public static string WindowClass(IntPtr hWnd)
    {
        var text = new StringBuilder(256);
        GetClassName(hWnd, text, text.Capacity);
        return text.ToString();
    }

    public static IntPtr[] WindowsForProcess(int processId)
    {
        var result = new List<IntPtr>();
        EnumWindows((hWnd, unused) => {
            uint owner;
            GetWindowThreadProcessId(hWnd, out owner);
            if (owner == processId) result.Add(hWnd);
            return true;
        }, IntPtr.Zero);
        return result.ToArray();
    }

    public static IntPtr[] ChildWindows(IntPtr parent)
    {
        var result = new List<IntPtr>();
        EnumChildWindows(parent, (hWnd, unused) => {
            result.Add(hWnd);
            return true;
        }, IntPtr.Zero);
        return result.ToArray();
    }
}
"@
}

$UiTreeScopeDescendants = [System.Windows.Automation.TreeScope]::Descendants
$UiTrueCondition = [System.Windows.Automation.Condition]::TrueCondition
$UiMenuItemType = [System.Windows.Automation.ControlType]::MenuItem
$UiEditType = [System.Windows.Automation.ControlType]::Edit
$UiButtonType = [System.Windows.Automation.ControlType]::Button
$WmCommand = 0x0111
$WmSetText = 0x000C
$BmClick = 0x00F5
$WmKeyDown = 0x0100
$WmKeyUp = 0x0101
$WmSysKeyDown = 0x0104
$WmSysKeyUp = 0x0105

function Write-ActivityLog {
    param([string] $Message)

    try {
        $line = "$(Get-Date -Format o) [$PID] $Message"
        Add-Content -LiteralPath (Join-Path $env:TEMP 'UTAU-Batch-Render.log') -Value $line -Encoding UTF8
    }
    catch { }
}

function Get-UiDescendants {
    param([System.Windows.Automation.AutomationElement] $Root)

    try {
        $items = $Root.FindAll($UiTreeScopeDescendants, $UiTrueCondition)
        for ($i = 0; $i -lt $items.Count; $i++) {
            $items.Item($i)
        }
    }
    catch {
        @()
    }
}

function Wait-WithUi {
    param(
        [int] $Milliseconds,
        [hashtable] $State
    )

    $until = (Get-Date).AddMilliseconds($Milliseconds)
    while ((Get-Date) -lt $until) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($State -and $State.CancelRequested) { return }
        Start-Sleep -Milliseconds 50
    }
}

function Set-WindowActive {
    param([IntPtr] $Handle)

    if ($Handle -eq [IntPtr]::Zero) { return }
    [UtauBatchRenderNative]::ShowWindow($Handle, 9) | Out-Null
    [UtauBatchRenderNative]::SetForegroundWindow($Handle) | Out-Null
}

function Get-OutputPath {
    param([string] $UstPath)

    [System.IO.Path]::ChangeExtension($UstPath, '.wav')
}

function Get-VoiceBankSettingPath {
    Join-Path $env:APPDATA 'UTAU-Batch-Render\voicebank.txt'
}

function Get-SavedVoiceBank {
    $path = Get-VoiceBankSettingPath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $saved = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8).Trim()
        if ($saved -and (Test-Path -LiteralPath $saved -PathType Container)) { return $saved }
    }

    $null
}

function Select-VoiceBank {
    param([string] $InitialPath)

    if ($InitialPath -and (Test-Path -LiteralPath $InitialPath -PathType Container) -and
        (Test-Path -LiteralPath (Join-Path $InitialPath 'oto.ini') -PathType Leaf)) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "前回の音源を使いますか？`n$InitialPath",
            '使用するシンガー音源',
            [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { return $InitialPath }
        if ($answer -eq [System.Windows.Forms.DialogResult]::Cancel) { return $null }
    }

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = '一括レンダリングに使う単独音音源フォルダを選択してください（oto.iniがあるフォルダ）'
    $dialog.ShowNewFolderButton = $false
    if ($InitialPath -and (Test-Path -LiteralPath $InitialPath -PathType Container)) {
        $dialog.SelectedPath = $InitialPath
    }

    try {
        while ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $voiceBank = (Get-Item -LiteralPath $dialog.SelectedPath).FullName
            if (-not (Test-Path -LiteralPath (Join-Path $voiceBank 'oto.ini') -PathType Leaf)) {
                [System.Windows.Forms.MessageBox]::Show(
                    'oto.iniが見つかりません。この音源のルートフォルダを選択してください。',
                    '音源フォルダを確認',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null
                continue
            }

            $settingsPath = Get-VoiceBankSettingPath
            $settingsDir = Split-Path -Parent $settingsPath
            New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [IO.File]::WriteAllText($settingsPath, $voiceBank, $utf8)
            return $voiceBank
        }
    }
    finally {
        $dialog.Dispose()
    }

    $null
}

function New-VoiceBankUstCopy {
    param(
        [string] $UstPath,
        [string] $VoiceBankPath
    )

    $bytes = [IO.File]::ReadAllBytes($UstPath)
    $offset = 0
    $encoding = $null
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = New-Object System.Text.UTF8Encoding($true)
        $offset = 3
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [Text.Encoding]::Unicode
        $offset = 2
    }
    else {
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        try {
            [void]$strictUtf8.GetString($bytes)
            $encoding = $strictUtf8
        }
        catch {
            $encoding = [Text.Encoding]::Default
        }
    }

    $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    $voiceDirMatch = [regex]::Match($text, '(?m)^VoiceDir=.*$')
    if (-not $voiceDirMatch.Success) {
        throw 'USTにVoiceDirがないため、選択した音源を適用できません。'
    }
    $voiceName = Split-Path -Leaf $VoiceBankPath
    $replacement = "VoiceDir=%VOICE%$voiceName"
    $updated = $text.Remove($voiceDirMatch.Index, $voiceDirMatch.Length).Insert($voiceDirMatch.Index, $replacement)

    $tempDir = Join-Path $env:TEMP 'UTAU-Batch-Render'
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    $tempPath = Join-Path $tempDir ('render-' + [guid]::NewGuid().ToString('N') + '.ust')
    [IO.File]::WriteAllText($tempPath, $updated, $encoding)
    $tempPath
}

function Get-NativeMenuText {
    param(
        [IntPtr] $Menu,
        [int] $Position
    )

    $text = New-Object System.Text.StringBuilder 512
    [UtauBatchRenderNative]::GetMenuString($Menu, [uint32]$Position, $text, $text.Capacity, 0x400) | Out-Null
    $text.ToString().Trim()
}

function Find-NativeRenderMenuCommand {
    param([IntPtr] $Menu)

    if ($Menu -eq [IntPtr]::Zero) { return $null }
    $count = [UtauBatchRenderNative]::GetMenuItemCount($Menu)
    for ($position = 0; $position -lt $count; $position++) {
        $text = Get-NativeMenuText $Menu $position
        $subMenu = [UtauBatchRenderNative]::GetSubMenu($Menu, $position)
        if ($text -match '(?i)wav.*(生成|render|file)|render.*wav|wav file') {
            $commandId = [UtauBatchRenderNative]::GetMenuItemID($Menu, $position)
            if ([int64]$commandId -ne 4294967295) {
                return [pscustomobject]@{ Id = $commandId; Text = $text }
            }
        }
        if ($subMenu -ne [IntPtr]::Zero) {
            $found = Find-NativeRenderMenuCommand $subMenu
            if ($found) { return $found }
        }
    }

    $null
}

function Post-UtauRenderShortcut {
    param([IntPtr] $MainWindowHandle)

    Set-WindowActive $MainWindowHandle
    # UTAU 0.4.19 has no Win32 menu handle, but its window handles Alt+P then G.
    $sent = @(
        [UtauBatchRenderNative]::PostMessage($MainWindowHandle, [uint32]$WmSysKeyDown, [IntPtr]0x50, [IntPtr]0x20000001)
        [UtauBatchRenderNative]::PostMessage($MainWindowHandle, [uint32]$WmSysKeyUp, [IntPtr]0x50, [IntPtr]0xC0200001)
        [UtauBatchRenderNative]::PostMessage($MainWindowHandle, [uint32]$WmKeyDown, [IntPtr]0x47, [IntPtr]0x00000001)
        [UtauBatchRenderNative]::PostMessage($MainWindowHandle, [uint32]$WmKeyUp, [IntPtr]0x47, [IntPtr]0xC0000001)
    )
    if ($sent -contains $false) {
        throw 'UTAUへのレンダー操作メッセージ送信に失敗しました。'
    }
}

function Find-UtauExe {
    $candidates = @(
        $env:UTAU_EXE,
        (Get-Command UTAU.exe -ErrorAction SilentlyContinue).Path,
        (Join-Path $env:ProgramFiles 'UTAU\UTAU.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'UTAU\UTAU.exe'),
        (Join-Path $env:LOCALAPPDATA 'UTAU\UTAU.exe'),
        (Join-Path $env:USERPROFILE 'UTAU\UTAU.exe')
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Get-Item -LiteralPath $candidate).FullName
        }
    }

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'UTAU.exeを選択してください'
    $dialog.Filter = 'UTAU.exe|UTAU.exe|実行ファイル|*.exe'
    $dialog.CheckFileExists = $true
    try {
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.FileName
        }
    }
    finally {
        $dialog.Dispose()
    }

    $null
}

function Get-UtauProjectWindowHandle {
    param(
        [System.Diagnostics.Process] $Process,
        [string] $UstPath
    )

    $fileName = [System.IO.Path]::GetFileName($UstPath)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($UstPath)
    $filePattern = [regex]::Escape($fileName)
    $basePattern = [regex]::Escape($baseName)

    foreach ($handle in [UtauBatchRenderNative]::WindowsForProcess($Process.Id)) {
        $className = [UtauBatchRenderNative]::WindowClass($handle)
        $title = [UtauBatchRenderNative]::WindowText($handle)
        if ($className -eq 'ThunderRT6FormDC' -and
            $title -notmatch '新規プロジェクト' -and
            ($title -match $filePattern -or $title -match $basePattern)) {
            return $handle
        }
    }

    [IntPtr]::Zero
}

function Get-UtauMainWindowHandle {
    param([System.Diagnostics.Process] $Process)

    foreach ($handle in [UtauBatchRenderNative]::WindowsForProcess($Process.Id)) {
        if ([UtauBatchRenderNative]::WindowClass($handle) -eq 'ThunderRT6Main') {
            return $handle
        }
    }

    [IntPtr]::Zero
}

function Wait-ForUtauMainWindow {
    param(
        [System.Diagnostics.Process] $Process,
        [hashtable] $State,
        [int] $Seconds = 15
    )

    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until) {
        if ($State.CancelRequested) { throw 'キャンセルされました。' }
        $handle = $null
        foreach ($candidate in [UtauBatchRenderNative]::WindowsForProcess($Process.Id)) {
            if ([UtauBatchRenderNative]::WindowClass($candidate) -eq 'ThunderRT6FormDC' -and
                [UtauBatchRenderNative]::WindowText($candidate) -match '新規プロジェクト') {
                $handle = $candidate
                break
            }
        }
        if (-not $handle) { $handle = Get-UtauMainWindowHandle $Process }
        if ($handle -ne [IntPtr]::Zero) { return $handle }
        Wait-WithUi 250 $State
    }

    Write-UtauWindowSnapshot $Process.Id
    throw 'UTAUのメイン画面が開きませんでした。'
}

function Dismiss-UtauVoiceReport {
    param(
        [int] $ProcessId,
        [hashtable] $State
    )

    foreach ($handle in [UtauBatchRenderNative]::WindowsForProcess($ProcessId)) {
        if ([UtauBatchRenderNative]::WindowText($handle) -notmatch '原音レポート') { continue }
        foreach ($child in [UtauBatchRenderNative]::ChildWindows($handle)) {
            if ([UtauBatchRenderNative]::WindowClass($child) -eq 'Button' -and
                [UtauBatchRenderNative]::WindowText($child) -match '閉じる|Close|OK') {
                [UtauBatchRenderNative]::SendMessage($child, [uint32]$BmClick, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
                Wait-WithUi 300 $State
                return
            }
        }
        [UtauBatchRenderNative]::PostMessage($handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        Wait-WithUi 300 $State
        return
    }
}

function Write-UtauWindowSnapshot {
    param([int] $ProcessId)

    foreach ($handle in [UtauBatchRenderNative]::WindowsForProcess($ProcessId)) {
        $className = [UtauBatchRenderNative]::WindowClass($handle)
        $title = [UtauBatchRenderNative]::WindowText($handle)
        if ($className -match 'Thunder|#32770' -or $title) {
            Write-ActivityLog "window snapshot handle=$handle class=$className title=$title"
        }
    }
}

function Wait-ForMainWindow {
    param(
        [System.Diagnostics.Process] $Process,
        [string] $UstPath,
        [hashtable] $State,
        [int] $Seconds = 15
    )

    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until) {
        if ($State.CancelRequested) { throw 'キャンセルされました。' }
        $handle = Get-UtauProjectWindowHandle $Process $UstPath
        if ($handle -ne [IntPtr]::Zero) { return $handle }
        Wait-WithUi 250 $State
    }

    Write-UtauWindowSnapshot $Process.Id
    throw 'UTAUのメイン画面が開きませんでした。'
}

function Open-UstInUtau {
    param(
        [System.Diagnostics.Process] $Process,
        [string] $UstPath,
        [hashtable] $State
    )

    Wait-ForUtauMainWindow $Process $State | Out-Null
    Wait-WithUi 1000 $State
    Dismiss-UtauVoiceReport $Process.Id $State
    Wait-ForMainWindow $Process $UstPath $State
}

function Find-RenderMenuItem {
    param([IntPtr] $MainWindowHandle)

    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($MainWindowHandle)
        foreach ($item in (Get-UiDescendants $root)) {
            if ($item.Current.ControlType -ne $UiMenuItemType) { continue }
            $name = $item.Current.Name
            if ($name -match '(?i)wav.*(生成|render|file)|render.*wav|wav file') {
                return $item
            }
        }
    }
    catch { }

    $null
}

function Invoke-RenderCommand {
    param(
        [IntPtr] $MainWindowHandle,
        [hashtable] $State
    )

    $menu = [UtauBatchRenderNative]::GetMenu($MainWindowHandle)
    $command = Find-NativeRenderMenuCommand $menu
    if ($command) {
        Write-ActivityLog "render menu found: $($command.Text), id=$($command.Id)"
        if ([UtauBatchRenderNative]::PostMessage(
            $MainWindowHandle,
            [uint32]$WmCommand,
            [IntPtr]$command.Id,
            [IntPtr]::Zero
        )) {
            return
        }
    }

    # UI Automation is retained for UTAU builds that expose an accessible menu.
    $menuItem = Find-RenderMenuItem $MainWindowHandle
    if ($menuItem) {
        try {
            $pattern = $menuItem.GetCurrentPattern(
                [System.Windows.Automation.InvokePattern]::Pattern
            )
            $pattern.Invoke()
            return
        }
        catch { }
    }

    Post-UtauRenderShortcut $MainWindowHandle
}

function Find-OutputDialog {
    param([int] $ProcessId)

    foreach ($handle in [UtauBatchRenderNative]::WindowsForProcess($ProcessId)) {
        $className = [UtauBatchRenderNative]::WindowClass($handle)
        $name = [UtauBatchRenderNative]::WindowText($handle)
        $children = @([UtauBatchRenderNative]::ChildWindows($handle))
        $hasEdit = $children | Where-Object {
            [UtauBatchRenderNative]::WindowClass($_) -eq 'Edit'
        } | Select-Object -First 1
        $hasSaveButton = $children | Where-Object {
            [UtauBatchRenderNative]::WindowClass($_) -eq 'Button' -and
            [UtauBatchRenderNative]::WindowText($_) -match '保存|Save|OK'
        } | Select-Object -First 1
        if ($className -eq '#32770' -or $name -match '出力ファイル名|名前を付けて保存|Save As|Output') {
            Write-ActivityLog "dialog candidate handle=$handle class=$className title=$name edit=$([bool]$hasEdit) save=$([bool]$hasSaveButton)"
        }
        if (($name -match '出力ファイル名|名前を付けて保存|Save As|Output' -or $className -eq '#32770') -and
            $hasEdit -and $hasSaveButton) {
            return $handle
        }
    }

    $null
}

function Wait-ForOutputDialog {
    param(
        [int] $ProcessId,
        [hashtable] $State,
        [int] $Seconds = 15
    )

    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until) {
        if ($State.CancelRequested) { throw 'キャンセルされました。' }
        $dialog = Find-OutputDialog $ProcessId
        if ($dialog) { return $dialog }
        Wait-WithUi 200 $State
    }

    $null
}

function Set-OutputFileName {
    param(
        [IntPtr] $DialogHandle,
        [string] $OutputPath
    )

    $editHandle = $null
    $buttonHandle = $null
    $children = @([UtauBatchRenderNative]::ChildWindows($DialogHandle))
    Write-ActivityLog "save dialog handle=$DialogHandle children=$($children.Count)"
    foreach ($child in $children) {
        $className = [UtauBatchRenderNative]::WindowClass($child)
        $text = [UtauBatchRenderNative]::WindowText($child)
        if (-not $editHandle -and $className -eq 'Edit') { $editHandle = $child }
        if ($className -eq 'Button' -and $text -match '保存|Save|OK') { $buttonHandle = $child }
    }

    if (-not $editHandle) { throw '出力ファイル名の入力欄が見つかりませんでした。' }
    if (-not $buttonHandle) { throw '保存ボタンが見つかりませんでした。' }

    [UtauBatchRenderNative]::SendMessage($editHandle, [uint32]$WmSetText, [IntPtr]::Zero, $OutputPath) | Out-Null
    [UtauBatchRenderNative]::SendMessage($buttonHandle, [uint32]$BmClick, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
}

function Assert-UstHeader {
    param([string] $UstPath)

    $head = @(Get-Content -LiteralPath $UstPath -TotalCount 100 -ErrorAction Stop)
    if ($head -notcontains '[#VERSION]' -or $head -notcontains '[#SETTING]') {
        throw 'UST形式ではありません（[#VERSION] または [#SETTING] がありません）。'
    }
}

function Wait-ForOutputFile {
    param(
        [string] $OutputPath,
        [System.Diagnostics.Process] $Process,
        [hashtable] $State,
        [int] $Seconds
    )

    $until = (Get-Date).AddSeconds($Seconds)
    $lastLength = -1L
    $stableChecks = 0
    $processExitedAt = $null

    while ((Get-Date) -lt $until) {
        if ($State.CancelRequested) { throw 'キャンセルされました。' }

        if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
            try {
                $length = (Get-Item -LiteralPath $OutputPath).Length
                $header = New-Object byte[] 4
                $stream = [System.IO.File]::Open(
                    $OutputPath,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::None
                )
                try {
                    [void]$stream.Read($header, 0, 4)
                }
                finally {
                    $stream.Dispose()
                }
                $isRiff = [System.Text.Encoding]::ASCII.GetString($header) -eq 'RIFF'
                if ($isRiff -and $length -gt 44 -and $length -eq $lastLength) {
                    $stableChecks++
                }
                else {
                    $stableChecks = 0
                }
                $lastLength = $length
                if ($stableChecks -ge 6) { return }
            }
            catch { }
        }
        try {
            $Process.Refresh()
            if ($Process.HasExited) {
                if (-not $processExitedAt) { $processExitedAt = Get-Date }
                # ponytail: child render tools get 60s after UTAU exits; raise only for unusually slow tools.
                if (((Get-Date) - $processExitedAt).TotalSeconds -ge 60 -and
                    -not (Test-Path -LiteralPath $OutputPath)) {
                    throw 'UTAUがWAVを作成する前に終了しました。'
                }
            }
            else {
                $processExitedAt = $null
            }
        }
        catch {
            if ($_.Exception.Message -like 'UTAUがWAV*') { throw }
        }

        Wait-WithUi 500 $State
    }

    throw "WAV生成がタイムアウトしました（${Seconds}秒）。"
}

function Stop-LaunchedUtau {
    param(
        [System.Diagnostics.Process] $Process,
        [hashtable] $State
    )

    if (-not $Process) { return }
    try {
        $Process.Refresh()
        if ($Process.HasExited) { return }
        $Process.CloseMainWindow() | Out-Null
        Wait-WithUi 1500 $State
        $Process.Refresh()
        if (-not $Process.HasExited) {
            $Process.Kill()
            $Process.WaitForExit(3000)
        }
    }
    catch { }
}

function Start-UtauProcess {
    param(
        [string] $UtauExe,
        [string] $WorkingDirectory,
        [string] $Arguments,
        [string] $VoiceRoot
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $UtauExe
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.EnvironmentVariables['VOICE'] = $VoiceRoot
    [System.Diagnostics.Process]::Start($startInfo)
}

function Process-Ust {
    param(
        [string] $UstPath,
        [string] $OutputPath,
        [string] $UtauExe,
        [hashtable] $State,
        [string] $VoiceBankPath
    )

    if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
        Write-ActivityLog "skip existing ust=$UstPath output=$OutputPath"
        return 'skipped'
    }

    $process = $null
    $renderUstPath = $UstPath
    $temporaryUstPath = $null
    $previousVoiceRoot = $env:VOICE
    try {
        Assert-UstHeader $UstPath
        $temporaryUstPath = New-VoiceBankUstCopy $UstPath $VoiceBankPath
        $renderUstPath = $temporaryUstPath
        $env:VOICE = (Split-Path -Parent $VoiceBankPath).TrimEnd('\') + '\'
        Write-ActivityLog "start ust=$UstPath output=$OutputPath"
        $arguments = '"' + $renderUstPath + '"'
        $process = Start-UtauProcess $UtauExe (Split-Path -Parent $UtauExe) $arguments $env:VOICE
        Write-ActivityLog "utau pid=$($process.Id)"
        Open-UstInUtau $process $renderUstPath $State
        $mainWindowHandle = Get-UtauProjectWindowHandle $process $renderUstPath
        if ($mainWindowHandle -eq [IntPtr]::Zero) { throw 'USTを開いた後のプロジェクト画面が見つかりませんでした。' }
        Write-ActivityLog "project window=$mainWindowHandle title=$([UtauBatchRenderNative]::WindowText($mainWindowHandle))"
        Set-WindowActive $mainWindowHandle
        Wait-WithUi 500 $State

        Invoke-RenderCommand $mainWindowHandle $State
        $dialog = Wait-ForOutputDialog $process.Id $State
        if (-not $dialog) {
            throw '出力ファイル名ダイアログが開きませんでした。'
        }

        Set-OutputFileName $dialog $OutputPath
        Wait-ForOutputFile $OutputPath $process $State $RenderTimeoutSeconds
        Write-ActivityLog "render complete output=$OutputPath"
        'rendered'
    }
    catch {
        Write-ActivityLog "failed ust=$UstPath error=$($_.Exception.Message)"
        throw
    }
    finally {
        Stop-LaunchedUtau $process $State
        if ($temporaryUstPath -and (Test-Path -LiteralPath $temporaryUstPath -PathType Leaf)) {
            Remove-Item -LiteralPath $temporaryUstPath -Force -ErrorAction SilentlyContinue
        }
        if ($null -eq $previousVoiceRoot) {
            Remove-Item Env:VOICE -ErrorAction SilentlyContinue
        }
        else {
            $env:VOICE = $previousVoiceRoot
        }
    }
}

function New-ProgressUi {
    param(
        [hashtable] $State,
        [int] $Total
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'UTAU 一括レンダリング'
    $form.Width = 620
    $form.Height = 390
    $form.StartPosition = 'CenterScreen'
    $form.MinimizeBox = $false

    $status = New-Object System.Windows.Forms.Label
    $status.Left = 12
    $status.Top = 12
    $status.Width = 580
    $status.Text = "準備中（全 $Total 件）"

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Left = 12
    $progress.Top = 40
    $progress.Width = 580
    $progress.Minimum = 0
    $progress.Maximum = [Math]::Max(1, $Total)

    $log = New-Object System.Windows.Forms.ListBox
    $log.Left = 12
    $log.Top = 75
    $log.Width = 580
    $log.Height = 235

    $button = New-Object System.Windows.Forms.Button
    $button.Left = 507
    $button.Top = 320
    $button.Width = 85
    $button.Text = 'キャンセル'

    $form.Controls.AddRange(@($status, $progress, $log, $button))
    $button.Add_Click(({
        if ($State.Done) {
            $form.Close()
        }
        else {
            $State.CancelRequested = $true
            $button.Enabled = $false
            $status.Text = '停止中…'
        }
    }).GetNewClosure())
    $form.Add_FormClosing(({
        param($sender, $eventArgs)
        if (-not $State.Done) {
            $State.CancelRequested = $true
            $eventArgs.Cancel = $true
        }
    }).GetNewClosure())

    [pscustomobject]@{
        Form = $form
        Status = $status
        Progress = $progress
        Log = $log
        Button = $button
    }
}

function Update-ProgressUi {
    param(
        $Ui,
        [string] $Status,
        [int] $Completed,
        [string] $LogLine
    )

    $Ui.Status.Text = $Status
    $Ui.Progress.Value = [Math]::Min($Ui.Progress.Maximum, [Math]::Max(0, $Completed))
    if ($LogLine) {
        [void]$Ui.Log.Items.Add($LogLine)
        $Ui.Log.TopIndex = [Math]::Max(0, $Ui.Log.Items.Count - 1)
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Invoke-SelfTest {
    $sample = Join-Path $env:TEMP '音声\song.ust'
    $expected = Join-Path $env:TEMP '音声\song.wav'
    if ((Get-OutputPath $sample) -ne $expected) {
        throw '出力ファイル名のセルフテストに失敗しました。'
    }

    $testRoot = Join-Path $env:TEMP ('UTAU-Batch-Render-selftest-' + [guid]::NewGuid().ToString('N'))
    $testVoice = Join-Path $testRoot 'voice'
    $testUst = Join-Path $testRoot 'sample.ust'
    $testCopy = $null
    try {
        New-Item -ItemType Directory -Force -Path $testVoice | Out-Null
        [IO.File]::WriteAllText((Join-Path $testVoice 'oto.ini'), '')
        $ustText = @"
[#VERSION]
UST Version1.2
[#SETTING]
VoiceDir=original
[#TRACKEND]
"@
        [IO.File]::WriteAllText($testUst, $ustText, [Text.Encoding]::UTF8)
        $testCopy = New-VoiceBankUstCopy $testUst $testVoice
        $copyText = [IO.File]::ReadAllText($testCopy, [Text.Encoding]::UTF8)
        $originalText = [IO.File]::ReadAllText($testUst, [Text.Encoding]::UTF8)
        if ($copyText -notmatch 'VoiceDir=%VOICE%voice') {
            throw '音源差し替えのセルフテストに失敗しました。'
        }
        if ($originalText -notmatch 'VoiceDir=original') {
            throw '元UST保護のセルフテストに失敗しました。'
        }
    }
    finally {
        if ($testCopy -and (Test-Path -LiteralPath $testCopy -PathType Leaf)) {
            Remove-Item -LiteralPath $testCopy -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $testRoot -PathType Container) {
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Output 'Self-test passed.'
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

if ($Worker) {
    $workerUst = @(
        foreach ($path in $InputPaths) {
            try {
                $item = Get-Item -LiteralPath $path -ErrorAction Stop
                if (-not $item.PSIsContainer -and $item.Extension -ieq '.ust') { $item.FullName }
            }
            catch { }
        }
    ) | Select-Object -First 1

    if (-not $workerUst -or -not $VoiceBankPath) { exit 2 }
    if (-not (Test-Path -LiteralPath $VoiceBankPath -PathType Container) -or
        -not (Test-Path -LiteralPath (Join-Path $VoiceBankPath 'oto.ini') -PathType Leaf)) { exit 2 }

    $workerUtauExe = Find-UtauExe
    if (-not $workerUtauExe) { exit 2 }
    $workerState = @{ CancelRequested = $false; Done = $false }
    try {
        $workerResult = Process-Ust $workerUst (Get-OutputPath $workerUst) $workerUtauExe $workerState $VoiceBankPath
        if ($workerResult -eq 'skipped') { exit 0 }
        exit 0
    }
    catch {
        Write-ActivityLog "worker failed ust=$workerUst error=$($_.Exception.Message)"
        exit 2
    }
}

$ustPaths = @(
    foreach ($path in $InputPaths) {
        try {
            $item = Get-Item -LiteralPath $path -ErrorAction Stop
            if (-not $item.PSIsContainer -and $item.Extension -ieq '.ust') {
                $item.FullName
            }
        }
        catch { }
    }
)

if ($ustPaths.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show(
        'USTファイルが選択されていません。',
        'UTAU 一括レンダリング',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
    exit 1
}

$utauExe = Find-UtauExe
if (-not $utauExe) {
    [System.Windows.Forms.MessageBox]::Show(
        'UTAU.exeが見つからないため終了しました。',
        'UTAU 一括レンダリング',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}

$voiceBankPath = $VoiceBankPath
if ($voiceBankPath) {
    if (-not (Test-Path -LiteralPath $voiceBankPath -PathType Container) -or
        -not (Test-Path -LiteralPath (Join-Path $voiceBankPath 'oto.ini') -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show(
            '指定した音源フォルダにoto.iniがありません。',
            '音源フォルダを確認',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        exit 1
    }
}
else {
    $voiceBankPath = Select-VoiceBank (Get-SavedVoiceBank)
}
if (-not $voiceBankPath) {
    exit 1
}

$state = @{
    CancelRequested = $false
    Done = $false
}
$ui = New-ProgressUi $state $ustPaths.Count
$ui.Form.Show()
[System.Windows.Forms.Application]::DoEvents()
Update-ProgressUi $ui "音源: $voiceBankPath" 0 "VOICE  $voiceBankPath"

$rendered = 0
$skipped = 0
$failed = 0
$completed = 0
$pending = New-Object System.Collections.ArrayList
$workerPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$scriptPath = $PSCommandPath

foreach ($ustPath in $ustPaths) {
    $outputPath = Get-OutputPath $ustPath
    $name = [System.IO.Path]::GetFileName($ustPath)
    if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
        $skipped++
        $completed++
        Update-ProgressUi $ui '既存WAVをスキップしました' $completed "SKIP  $name"
        continue
    }

    try {
        $workerArguments = '-NoProfile -ExecutionPolicy Bypass -STA -File "{0}" -Worker -RenderTimeoutSeconds {1} -VoiceBankPath "{2}" "{3}"' -f `
            $scriptPath, $RenderTimeoutSeconds, $voiceBankPath, $ustPath
        $worker = Start-Process -FilePath $workerPowerShell -ArgumentList $workerArguments -WindowStyle Hidden -PassThru
        [void]$pending.Add([pscustomobject]@{
            Process = $worker
            UstPath = $ustPath
            OutputPath = $outputPath
            Name = $name
        })
    }
    catch {
        $failed++
        $completed++
        Update-ProgressUi $ui '起動に失敗しました。次へ進みます' $completed "FAIL  $name : $($_.Exception.Message)"
    }
}

while ($pending.Count -gt 0) {
    if ($state.CancelRequested) {
        $ui.Status.Text = "停止要求を受け付けました。起動済みの処理を待っています（残り $($pending.Count) 件）"
    }

    foreach ($job in @($pending)) {
        $job.Process.Refresh()
        if (-not $job.Process.HasExited) { continue }

        $completed++
        if ($job.Process.ExitCode -eq 0 -and (Test-Path -LiteralPath $job.OutputPath -PathType Leaf)) {
            $rendered++
            Update-ProgressUi $ui 'WAVを生成しました' $completed "DONE  $($job.Name) -> $([System.IO.Path]::GetFileName($job.OutputPath))"
        }
        else {
            $failed++
            Update-ProgressUi $ui '失敗しました。次へ進みます' $completed "FAIL  $($job.Name)"
        }
        [void]$pending.Remove($job)
    }

    if ($pending.Count -gt 0) { Wait-WithUi 500 $state }
}

$state.Done = $true
$ui.Button.Text = '閉じる'
$ui.Button.Enabled = $true
$summary = "完了: $rendered / スキップ: $skipped / 失敗: $failed"
if ($state.CancelRequested -and $index -lt $ustPaths.Count) {
    $summary += " / キャンセル: $($ustPaths.Count - $index)"
}
$ui.Status.Text = $summary
[void]$ui.Log.Items.Add($summary)
[System.Windows.Forms.Application]::DoEvents()
[System.Windows.Forms.Application]::Run($ui.Form)
