[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [switch]$SkipTests
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$allowedRoot = [System.IO.Path]::GetFullPath('D:\lizd')
$allowedPrefix = $allowedRoot.TrimEnd('\') + '\'
if (-not $repositoryRoot.StartsWith($allowedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "TmuxHub must be built from a repository below $allowedRoot."
}

$appProject = Join-Path $PSScriptRoot 'TmuxHub.Windows\TmuxHub.Windows.csproj'
$testProject = Join-Path $PSScriptRoot 'TmuxHub.Windows.Tests\TmuxHub.Windows.Tests.csproj'
foreach ($path in @($appProject, $testProject)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required project not found: $path"
    }
}

$dotnet = Get-Command dotnet -CommandType Application -ErrorAction Stop

function Invoke-DotNet {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

    & $dotnet.Source @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

Push-Location $repositoryRoot
try {
    Invoke-DotNet restore $testProject
    Invoke-DotNet build $testProject --configuration $Configuration --no-restore
    if (-not $SkipTests) {
        Invoke-DotNet run --project $testProject --configuration $Configuration --no-build
    }
}
finally {
    Pop-Location
}

Write-Host "TmuxHub Windows build completed ($Configuration)."
