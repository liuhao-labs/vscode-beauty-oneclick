# Shared by the installer and the isolated regression tests. No work runs on import.
function Test-PathsOverlap {
    param([string]$First, [string]$Second)
    $a = [IO.Path]::GetFullPath($First).TrimEnd('\', '/')
    $b = [IO.Path]::GetFullPath($Second).TrimEnd('\', '/')
    return ($a -ieq $b -or $a.StartsWith($b + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $b.StartsWith($a + '\', [StringComparison]::OrdinalIgnoreCase))
}

function Assert-NoLinkedPath {
    param([string]$Path, [switch]$Recurse)
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Linked paths are not supported for backup or migration: $cursor"
        }
        $cursor = Split-Path -Parent $cursor
    }
    if ($Recurse -and (Test-Path -LiteralPath $Path -PathType Container)) {
        $pending = New-Object 'System.Collections.Generic.Stack[string]'
        $pending.Push($Path)
        while ($pending.Count) {
            foreach ($child in Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop) {
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw "Linked paths are not supported for backup or migration: $($child.FullName)"
                }
                if ($child.PSIsContainer) { $pending.Push($child.FullName) }
            }
        }
    }
}

function Assert-MigrationSource {
    param([string]$Source, [string[]]$Targets)
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "Source is not a directory: $Source" }
    Assert-NoLinkedPath -Path $Source -Recurse
    if (-not (Get-ChildItem -LiteralPath $Source -Recurse -File -Force -ErrorAction Stop | Select-Object -First 1)) {
        throw "Refusing an empty migration source: $Source"
    }
    foreach ($target in $Targets) {
        if (Test-PathsOverlap $Source $target) { throw "Source overlaps an active target: $Source -> $target" }
    }
}

function Get-AutoProfile {
    param([string[]]$Roots, [bool]$NeedUserData, [bool]$NeedExtensions)
    $profiles = @{}
    $partial = $false
    foreach ($root in $Roots) {
        foreach ($layout in @(
            @('user-data', 'extensions'), @('Code', '.vscode\extensions'), @('AppData\Roaming\Code', '.vscode\extensions')
        )) {
            $userPath = Join-Path $root $layout[0]
            $extPath = Join-Path $root $layout[1]
            $hasUser = Test-Path -LiteralPath $userPath -PathType Container
            $hasExt = Test-Path -LiteralPath $extPath -PathType Container
            if (($NeedUserData -and $hasUser) -or ($NeedExtensions -and $hasExt)) { $partial = $true }
            if (($NeedUserData -and -not $hasUser) -or ($NeedExtensions -and -not $hasExt)) { continue }
            $user = if ($NeedUserData) { (Resolve-Path -LiteralPath $userPath).Path } else { $null }
            $ext = if ($NeedExtensions) { (Resolve-Path -LiteralPath $extPath).Path } else { $null }
            $profiles["$user|$ext"] = [pscustomobject]@{ UserData = $user; Extensions = $ext }
        }
    }
    if ($profiles.Count -gt 1) { throw 'Multiple profiles found. Pass explicit source paths; nothing has been changed.' }
    if ($profiles.Count -eq 1) { return @($profiles.Values)[0] }
    if ($partial) { throw 'Only incomplete profiles found. Supply both source paths, or explicitly skip the missing restore step.' }
    return [pscustomobject]@{ UserData = $null; Extensions = $null }
}

function Resolve-SetupPlan {
    if ($CleanFirst -and ($SkipVSCodeInstall -or $SkipUserData -or $SkipExtensions)) {
        throw 'CleanFirst cannot be combined with SkipVSCodeInstall, SkipUserData or SkipExtensions.'
    }
    if ($ForceDownload -and $SkipVSCodeInstall) { throw 'ForceDownload conflicts with SkipVSCodeInstall.' }
    if ($PayloadPath -and $ArchivePath) { throw 'Specify PayloadPath or ArchivePath, not both.' }
    if (($SkipUserData -and $UserDataPath) -or ($SkipExtensions -and $ExtensionsPath) -or ($SkipFonts -and $FontsPath)) {
        throw 'A source path cannot be combined with its corresponding skip switch.'
    }
    if ($SkipVSCodeInstall -and -not (Get-CodeExe)) { throw 'SkipVSCodeInstall requires an existing VS Code installation.' }

    $payload = Get-PayloadRoot
    if ($payload -and -not (Test-Path -LiteralPath $payload -PathType Container)) { throw "Payload is not a directory: $payload" }
    $user = Resolve-OptionalSourcePath -Path $UserDataPath -Name 'UserDataPath'
    $ext = Resolve-OptionalSourcePath -Path $ExtensionsPath -Name 'ExtensionsPath'
    if ($payload) {
        if (-not $SkipUserData -and -not $user) { $user = Resolve-OptionalSourcePath (Join-Path $payload 'user-data') 'Payload user-data' }
        if (-not $SkipExtensions -and -not $ext) { $ext = Resolve-OptionalSourcePath (Join-Path $payload 'extensions') 'Payload extensions' }
    }
    elseif ($user -or $ext) {
        if ((-not $SkipUserData -and -not $user) -or (-not $SkipExtensions -and -not $ext)) {
            throw 'Supply both source paths, or explicitly skip the other restore step. Automatic and explicit sources are not mixed.'
        }
    }
    elseif (-not $SkipUserData -or -not $SkipExtensions) {
        $profile = Get-AutoProfile -Roots @(Get-AutoProfileRoots) -NeedUserData (-not $SkipUserData) -NeedExtensions (-not $SkipExtensions)
        $user = $profile.UserData
        $ext = $profile.Extensions
    }
    if ($CleanFirst -and (-not $user -or -not $ext)) { throw 'CleanFirst requires valid user-data and extension sources.' }

    $targets = @((Join-Path $env:APPDATA 'Code'), (Join-Path $env:USERPROFILE '.vscode\extensions'))
    if ($CleanFirst) { $targets += @((Join-Path $env:LOCALAPPDATA 'Code'), (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code')) }
    foreach ($source in @($user, $ext)) {
        if ($source) { Assert-MigrationSource -Source $source -Targets $targets }
    }
    if ($user -and -not (Test-Path -LiteralPath (Join-Path $user 'User') -PathType Container)) {
        throw 'User-data source must contain a User directory copied from the VS Code profile.'
    }
    if ($ext -and -not (Get-ChildItem -LiteralPath $ext -Directory -Force |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'package.json') -PathType Leaf } | Select-Object -First 1)) {
        throw 'Extension source must contain at least one extension directory with package.json.'
    }
    foreach ($target in $targets) { Assert-NoLinkedPath -Path $target -Recurse }

    $fonts = $null
    if (-not $SkipFonts) {
        $fonts = Resolve-OptionalSourcePath -Path $FontsPath -Name 'FontsPath'
        if (-not $fonts -and $payload -and (Test-Path -LiteralPath (Join-Path $payload 'fonts'))) { $fonts = Join-Path $payload 'fonts' }
        if (-not $fonts) { $fonts = Get-RepositoryFontsRoot }
        if (-not $fonts) { throw 'No font source found. Use SkipFonts if fonts are not needed.' }
        Assert-MigrationSource -Source $fonts -Targets ($targets + @((Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts')))
        $fontFiles = @(Get-ChildItem -LiteralPath $fonts -Recurse -File -Force | Where-Object { $_.Extension -in @('.ttf', '.ttc', '.otf') })
        if (-not $fontFiles.Count) { throw "No font files found: $fonts" }
        if (@($fontFiles | Group-Object Name | Where-Object Count -gt 1).Count) { throw 'Duplicate font filenames in the source would overwrite each other.' }
    }

    $backupBase = if ($BackupPath) { [IO.Path]::GetFullPath($BackupPath) } else { Join-Path $env:LOCALAPPDATA 'VSCodeBeauty\Backups' }
    if ((Test-Path -LiteralPath $backupBase) -and -not (Test-Path -LiteralPath $backupBase -PathType Container)) {
        throw 'BackupPath must be a directory, not a file.'
    }
    foreach ($path in @($targets) + @($user, $ext, $fonts, (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'))) {
        if ($path -and (Test-PathsOverlap $backupBase $path)) { throw "Backup location overlaps a source or target: $backupBase" }
    }
    Assert-NoLinkedPath -Path $backupBase
    if (-not $SkipWorkbenchCss) {
        $cssPaths = @(Get-VSCodeWorkbenchCssPaths)
        if (-not $cssPaths.Count -and (Get-CodeExe)) { throw 'No supported workbench CSS found in the existing installation.' }
        foreach ($cssPath in $cssPaths) {
            $null = Remove-BeautyCssBlocks ([IO.File]::ReadAllText($cssPath))
            $null = Get-ProductChecksumInfo $cssPath
        }
    }
    Stop-VSCode
    if ($user) { Write-Host "User-data source: $user" }
    if ($ext) { Write-Host "Extension source: $ext" }
    return [pscustomobject]@{ UserData = $user; Extensions = $ext; Fonts = $fonts; BackupBase = $backupBase }
}

function Backup-SetupState {
    param([object]$Plan)
    $script:SetupBackupRoot = Join-Path $Plan.BackupBase ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:SetupBackupRoot -ErrorAction Stop | Out-Null
    if (-not $CleanFirst) {
        if ($Plan.UserData -and (Test-Path -LiteralPath (Join-Path $env:APPDATA 'Code'))) {
            Invoke-Robocopy -Source (Join-Path $env:APPDATA 'Code') -Destination (Join-Path $script:SetupBackupRoot 'user-data') -Mirror:$false
        }
        if ($Plan.Extensions -and (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.vscode\extensions'))) {
            Invoke-Robocopy -Source (Join-Path $env:USERPROFILE '.vscode\extensions') -Destination (Join-Path $script:SetupBackupRoot 'extensions') -Mirror:$false
        }
    }
    $settings = Join-Path $env:APPDATA 'Code\User\settings.json'
    if (Test-Path -LiteralPath $settings) { Copy-Item -LiteralPath $settings -Destination (Join-Path $script:SetupBackupRoot 'settings.json') -ErrorAction Stop }
    if ($Plan.Fonts) { Backup-CurrentUserFonts -Source $Plan.Fonts -BackupRoot $script:SetupBackupRoot }
    Write-Utf8NoBom -Path (Join-Path $script:SetupBackupRoot 'sources.json') -Value ($Plan | ConvertTo-Json)
    Write-Ok "Backup ready: $script:SetupBackupRoot"
}

function Backup-CurrentUserFonts {
    param([string]$Source, [string]$BackupRoot)
    $fontRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    Assert-NoLinkedPath -Path $fontRoot
    $regPath = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    $registry = if (Test-Path -LiteralPath $regPath) { Get-Item -LiteralPath $regPath } else { $null }
    $fontBackup = Join-Path $BackupRoot 'fonts'
    New-Item -ItemType Directory -Path $fontBackup | Out-Null
    $records = foreach ($font in Get-ChildItem -LiteralPath $Source -Recurse -File -Force | Where-Object { $_.Extension -in @('.ttf', '.ttc', '.otf') }) {
        $target = Join-Path $fontRoot $font.Name
        Assert-NoLinkedPath -Path $target
        $exists = Test-Path -LiteralPath $target
        if ($exists) { Copy-Item -LiteralPath $target -Destination (Join-Path $fontBackup $font.Name) -ErrorAction Stop }
        $name = Get-FontRegistryValueName -Font $font
        $registered = $registry -and ($registry.GetValueNames() -contains $name)
        [pscustomobject]@{
            Path = $target; FileExisted = $exists; RegistryPath = $regPath; Name = $name; Registered = [bool]$registered
            Value = $(if ($registered) { $registry.GetValue($name) } else { $null })
            Kind = $(if ($registered) { $registry.GetValueKind($name).ToString() } else { $null })
        }
    }
    $records | Export-Clixml -LiteralPath (Join-Path $BackupRoot 'fonts-before.xml') -Encoding UTF8
}

function Assert-FontLoaded {
    param([int]$Count, [string]$Path)
    if ($Count -le 0) { throw "Windows did not load font: $Path. Check the font file and permissions; original files and registry values are in the backup." }
}

function Set-WorkbenchCss {
    param([string]$CssPath, [string]$CssBlock)
    Assert-NoLinkedPath -Path $CssPath
    $newContent = (Remove-BeautyCssBlocks ([IO.File]::ReadAllText($CssPath))).TrimEnd() + $CssBlock + [Environment]::NewLine
    $info = Get-ProductChecksumInfo $CssPath
    Assert-NoLinkedPath -Path $info.Path
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $cssBackup = "$CssPath.bak-$stamp"
    $productBackup = "$($info.Path).bak-$stamp"
    Copy-Item -LiteralPath $CssPath -Destination $cssBackup -ErrorAction Stop
    Copy-Item -LiteralPath $info.Path -Destination $productBackup -ErrorAction Stop
    try {
        Write-Utf8NoBom -Path $CssPath -Value $newContent
        $hash = Get-Base64Sha256NoPadding $CssPath
        Set-ObjectProperty -Object $info.Product.checksums -Name $info.Key -Value $hash
        Write-Utf8NoBom -Path $info.Path -Value (($info.Product | ConvertTo-Json -Depth 100) + [Environment]::NewLine)
        $verified = Get-ProductChecksumInfo $CssPath
        if ($verified.Product.checksums.($info.Key) -ne (Get-Base64Sha256NoPadding $CssPath)) { throw 'CSS checksum verification failed.' }
    }
    catch {
        Copy-Item -LiteralPath $cssBackup -Destination $CssPath -Force -ErrorAction Stop
        Copy-Item -LiteralPath $productBackup -Destination $info.Path -Force -ErrorAction Stop
        throw
    }
    Write-Ok "Patched CSS. Backup: $cssBackup"
    Write-Ok "Updated product checksum: $($info.Key). Backup: $productBackup"
}

function Remove-BeautyCssBlocks {
    param([string]$Content)
    foreach ($name in @('vscode-beauty-oneclick', 'vscode-beautify-auto', 'vscode-beauty-safe')) {
        $start = [regex]::Escape("/* $name start */")
        $end = [regex]::Escape("/* $name end */")
        $inside = $false
        foreach ($token in [regex]::Matches($Content, "$start|$end")) {
            $isStart = $token.Value -eq "/* $name start */"
            if ($isStart -eq $inside) { throw "Incomplete or nested CSS markers for $name. Restore the original CSS before retrying." }
            $inside = $isStart
        }
        if ($inside) { throw "Incomplete CSS markers for $name. Restore the original CSS before retrying." }
        $Content = [regex]::Replace($Content, "$start.*?$end\s*", '', [Text.RegularExpressions.RegexOptions]::Singleline)
    }
    return $Content
}

function Get-ProductChecksumInfo {
    param([string]$CssPath)
    $full = [IO.Path]::GetFullPath($CssPath)
    $needle = '\resources\app\out\'
    $index = $full.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase)
    if ($index -lt 0) { throw "Cannot locate product.json for $CssPath" }
    $productPath = Join-Path $full.Substring(0, $index + '\resources\app'.Length) 'product.json'
    $product = [IO.File]::ReadAllText($productPath) | ConvertFrom-Json
    $key = $full.Substring($index + $needle.Length).Replace('\', '/')
    if (-not $product.checksums -or -not ($product.checksums.PSObject.Properties.Name -contains $key)) {
        throw "Missing checksum entry $key in $productPath"
    }
    return [pscustomobject]@{ Path = $productPath; Product = $product; Key = $key }
}

function Invoke-SetupStep {
    param([string]$Name, [scriptblock]$Action, [string]$SkipReason)
    if ($SkipReason) {
        $script:StepResults.Add([pscustomobject]@{ Step = $Name; Status = 'Skipped'; Detail = $SkipReason })
        return
    }
    $before = $script:StepWarnings
    try {
        & $Action
        $status = if ($script:StepWarnings -gt $before) { 'Warning' } else { 'Success' }
        $script:StepResults.Add([pscustomobject]@{ Step = $Name; Status = $status; Detail = '' })
    }
    catch {
        $script:StepResults.Add([pscustomobject]@{ Step = $Name; Status = 'Failed'; Detail = $_.Exception.Message })
        throw
    }
}

function Show-SetupSummary {
    $script:StepResults | Format-Table Step, Status, Detail -Wrap | Out-Host
    if ($script:SetupBackupRoot) { Write-Host "Backup: $script:SetupBackupRoot" }
}
