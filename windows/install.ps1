[CmdletBinding()]
param(
    [switch]$SkipTests
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$allowedRoot = [System.IO.Path]::GetFullPath('D:\lizd')
$allowedPrefix = $allowedRoot.TrimEnd('\') + '\'
if (-not $repositoryRoot.StartsWith($allowedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "TmuxHub must be installed from a repository below $allowedRoot."
}

$buildScript = Join-Path $PSScriptRoot 'build.ps1'
$appProject = Join-Path $PSScriptRoot 'TmuxHub.Windows\TmuxHub.Windows.csproj'
$publishDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'publish'))
$shortcutPath = [System.IO.Path]::GetFullPath('D:\lizd\app\TmuxHub.lnk')
$shortcutParent = Split-Path -Parent $shortcutPath

if (-not (Test-Path -LiteralPath $shortcutParent -PathType Container)) {
    throw "Shortcut directory not found: $shortcutParent"
}

& $buildScript -Configuration Release -SkipTests:$SkipTests

$dotnet = Get-Command dotnet -CommandType Application -ErrorAction Stop
& $dotnet.Source publish $appProject `
    --configuration Release `
    --runtime win-x64 `
    --self-contained false `
    --output $publishDirectory
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE."
}

$executable = Join-Path $publishDirectory 'TmuxHub.Windows.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw "Published executable not found: $executable"
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $null
try {
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $executable
    $shortcut.WorkingDirectory = $publishDirectory
    $shortcut.IconLocation = "$executable,0"
    $shortcut.Description = 'TmuxHub for Windows'
    $shortcut.Save()
}
finally {
    if ($null -ne $shortcut) {
        [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
    }
    [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class TmuxHubShellNotification
{
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(
        uint eventId,
        uint flags,
        IntPtr item1,
        IntPtr item2);
}
'@
[TmuxHubShellNotification]::SHChangeNotify(
    0x08000000,
    0x1000,
    [IntPtr]::Zero,
    [IntPtr]::Zero)

Write-Host "Published framework-dependent win-x64 app to $publishDirectory"
Write-Host "Created shortcut at $shortcutPath"
