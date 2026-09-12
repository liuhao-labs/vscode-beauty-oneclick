# Run with PowerShell 7 or Windows PowerShell 5.1. No external test modules required.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\Install-VSCodeBeautyOneClick.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('VSCodeBeautyTests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$savedEnvironment = @{}
foreach ($name in @('APPDATA', 'LOCALAPPDATA', 'USERPROFILE')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, (Join-Path $testRoot $name), 'Process')
    New-Item -ItemType Directory -Path (Join-Path $testRoot $name) | Out-Null
}
$script:Passed = 0
$script:Failed = 0
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    try { & $Action } catch {
        if ($_.Exception.Message -notlike $Pattern) { throw "Unexpected failure: $($_.Exception.Message)" }
        return
    }
    throw "Expected failure: $Pattern"
}
function New-Fixture {
    param([string]$Name, [string]$Content = 'fixture')
    $path = Join-Path $testRoot $Name
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [IO.File]::WriteAllText($path, $Content, [Text.UTF8Encoding]::new($false))
    return $path
}
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:Passed++; Write-Host "PASS $Name" }
    catch { $script:Failed++; Write-Host "FAIL ${Name}: $($_.Exception.Message)" -ForegroundColor Red }
}
# These boundaries never probe or modify the real VS Code installation.
function Get-CodeExe { return (Join-Path $testRoot 'Code.exe') }
function Get-VSCodeWorkbenchCssPaths { return @() }
function Get-AutoProfileRoots { return @((Join-Path $testRoot 'profiles')) }
function Get-PayloadRoot { return $null }
function Stop-VSCode { }
$SkipVSCodeInstall = $true
$SkipWorkbenchCss = $true
$SkipFonts = $true
$BackupPath = Join-Path $testRoot 'backups'

try {
    Test-Case 'invalid parameter combination stops before any backup or installation' {
        $CleanFirst = $true
        function Backup-SetupState { throw 'BACKUP MUST NOT RUN' }
        function Install-VSCode { throw 'INSTALL MUST NOT RUN' }
        Assert-Throws { Invoke-BeautySetup } '*CleanFirst cannot be combined*'
    }
    Test-Case 'missing source stops before any target modification' {
        $UserDataPath = Join-Path $testRoot 'missing'
        $SkipExtensions = $true
        function Backup-SetupState { throw 'BACKUP MUST NOT RUN' }
        Assert-Throws { Invoke-BeautySetup } '*UserDataPath does not exist*'
    }
    Test-Case 'empty sources cannot erase an existing target' {
        $empty = Join-Path $testRoot 'empty'
        New-Item -ItemType Directory -Path $empty | Out-Null
        Assert-Throws { Assert-MigrationSource $empty @((Join-Path $testRoot 'target')) } '*empty migration source*'
    }
    Test-Case 'equal and nested source/target paths are rejected' {
        $file = New-Fixture 'overlap\source\keep.txt'
        $source = Split-Path -Parent $file
        Assert-Throws { Assert-MigrationSource $source @($source) } '*overlaps*'
        Assert-Throws { Assert-MigrationSource $source @((Split-Path -Parent $source)) } '*overlaps*'
        Assert-Throws { Invoke-Robocopy $source (Join-Path $source 'nested') } '*overlap*'
    }
    Test-Case 'junctions cannot redirect a migration' {
        $file = New-Fixture 'junction-destination\keep.txt'
        $link = Join-Path $testRoot 'junction-source'
        New-Item -ItemType Junction -Path $link -Target (Split-Path -Parent $file) | Out-Null
        try { Assert-Throws { Assert-MigrationSource $link @((Join-Path $testRoot 'other')) } '*Linked paths*' }
        finally { [IO.Directory]::Delete($link) }
    }
    Test-Case 'two incomplete profiles are never mixed' {
        $null = New-Fixture 'split-a\user-data\User\settings.json' '{}'
        $null = New-Fixture 'split-b\extensions\sample\package.json' '{}'
        Assert-Throws { Get-AutoProfile @((Join-Path $testRoot 'split-a'), (Join-Path $testRoot 'split-b')) $true $true } '*incomplete profiles*'
    }
    Test-Case 'one complete profile resolves both sources together' {
        $null = New-Fixture 'complete\user-data\User\settings.json' '{}'
        $null = New-Fixture 'complete\extensions\sample\package.json' '{}'
        $root = Join-Path $testRoot 'complete'
        $profile = Get-AutoProfile @($root, $root) $true $true
        Assert-True ($profile.UserData -eq (Join-Path $root 'user-data')) 'Wrong user-data source'
        Assert-True ($profile.Extensions -eq (Join-Path $root 'extensions')) 'Wrong extensions source'
    }
    Test-Case 'multiple complete profiles fail instead of choosing silently' {
        $null = New-Fixture 'complete-2\user-data\User\settings.json' '{}'
        $null = New-Fixture 'complete-2\extensions\sample\package.json' '{}'
        Assert-Throws { Get-AutoProfile @((Join-Path $testRoot 'complete'), (Join-Path $testRoot 'complete-2')) $true $true } '*Multiple profiles*'
    }
    Test-Case 'explicit sources are not supplemented with auto-detected data' {
        $UserDataPath = Join-Path $testRoot 'complete\user-data'
        Assert-Throws { Resolve-SetupPlan } '*Supply both source paths*'
    }
    Test-Case 'unrelated nonempty directories are not accepted as a profile' {
        $null = New-Fixture 'not-a-profile\readme.txt' 'unrelated data'
        $UserDataPath = Join-Path $testRoot 'not-a-profile'
        $SkipExtensions = $true
        Assert-Throws { Resolve-SetupPlan } '*must contain a User directory*'
    }
    Test-Case 'backup location cannot be nested in a mirror target' {
        $SkipUserData = $true
        $SkipExtensions = $true
        $BackupPath = Join-Path $env:APPDATA 'Code\backup'
        Assert-Throws { Resolve-SetupPlan } '*Backup location overlaps*'
    }
    Test-Case 'mirror replacement keeps original data and plugins in automatic backup' {
        $oldUser = New-Fixture 'APPDATA\Code\User\original.json' '{"old":true}'
        $oldExt = New-Fixture 'USERPROFILE\.vscode\extensions\old\package.json' '{"old":true}'
        $UserDataPath = Join-Path $testRoot 'complete\user-data'
        $ExtensionsPath = Join-Path $testRoot 'complete\extensions'
        $plan = Resolve-SetupPlan
        Backup-SetupState $plan
        Restore-UserData
        Restore-Extensions
        Assert-True (Test-Path -LiteralPath (Join-Path $script:SetupBackupRoot 'user-data\User\original.json')) 'Old user data was not backed up'
        Assert-True (Test-Path -LiteralPath (Join-Path $script:SetupBackupRoot 'extensions\old\package.json')) 'Old extension was not backed up'
        Assert-True (-not (Test-Path -LiteralPath $oldUser)) 'Mirror did not replace old target'
        Assert-True (Test-Path -LiteralPath (Join-Path $env:APPDATA 'Code\User\settings.json')) 'New data missing'
        Assert-True (-not (Test-Path -LiteralPath $oldExt)) 'Old plugin still in mirror target'
    }
    Test-Case 'backup failure aborts before restore or cleanup' {
        $UserDataPath = Join-Path $testRoot 'complete\user-data'
        $ExtensionsPath = Join-Path $testRoot 'complete\extensions'
        function Invoke-Robocopy { throw 'SIMULATED BACKUP FAILURE' }
        function Restore-UserData { throw 'RESTORE MUST NOT RUN' }
        function Clean-StandardVSCodeState { throw 'CLEAN MUST NOT RUN' }
        Assert-Throws { Invoke-BeautySetup } '*SIMULATED BACKUP FAILURE*'
    }
    Test-Case 'full orchestration restores the validated sources after backup' {
        $UserDataPath = Join-Path $testRoot 'complete\user-data'
        $ExtensionsPath = Join-Path $testRoot 'complete\extensions'
        function New-VSCodeShortcut { }
        function Show-Verification { }
        Invoke-BeautySetup
        Assert-True (Test-Path -LiteralPath (Join-Path $script:SetupBackupRoot 'user-data\User\settings.json')) 'Orchestration skipped backup'
        Assert-True (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.vscode\extensions\sample\package.json')) 'Orchestration lost extension source'
    }
    Test-Case 'damaged CSS markers fail promptly' {
        foreach ($content in @('/* vscode-beauty-oneclick start */', '/* vscode-beauty-safe end */', '/* vscode-beautify-auto start *//* vscode-beautify-auto start *//* vscode-beautify-auto end */')) {
            Assert-Throws { Remove-BeautyCssBlocks $content } '*CSS markers*'
        }
    }
    $script:CssFile = New-Fixture 'app\resources\app\out\vs\workbench\workbench.desktop.main.css' 'body { color: red; }'
    $script:ProductFile = New-Fixture 'app\resources\app\product.json' '{"checksums":{"vs/workbench/workbench.desktop.main.css":"original"}}'
    $script:CssBlock = "`n/* vscode-beauty-oneclick start */`n.test { color: blue; }`n/* vscode-beauty-oneclick end */"
    Test-Case 'CSS patch is repeatable and writes a matching checksum without BOM' {
        Set-WorkbenchCss $script:CssFile $script:CssBlock
        Set-WorkbenchCss $script:CssFile $script:CssBlock
        $raw = [IO.File]::ReadAllText($script:CssFile)
        Assert-True ([regex]::Matches($raw, '/\* vscode-beauty-oneclick start \*/').Count -eq 1) 'CSS patch duplicated'
        $info = Get-ProductChecksumInfo $script:CssFile
        Assert-True ($info.Product.checksums.($info.Key) -eq (Get-Base64Sha256NoPadding $script:CssFile)) 'Checksum mismatch'
        $bytes = [IO.File]::ReadAllBytes($script:ProductFile)
        Assert-True (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'BOM was written'
    }
    Test-Case 'missing product checksum prevents CSS modification' {
        $badCss = New-Fixture 'bad-app\resources\app\out\vs\workbench\workbench.desktop.main.css' 'original'
        $null = New-Fixture 'bad-app\resources\app\product.json' '{}'
        Assert-Throws { Set-WorkbenchCss $badCss $script:CssBlock } '*Missing checksum entry*'
        Assert-True ([IO.File]::ReadAllText($badCss) -eq 'original') 'CSS changed despite invalid product.json'
    }
    Test-Case 'failed product write rolls back both files byte for byte' {
        $cssBefore = (Get-FileHash -LiteralPath $script:CssFile).Hash
        $productBefore = (Get-FileHash -LiteralPath $script:ProductFile).Hash
        function Write-Utf8NoBom {
            param([string]$Path, [string]$Value)
            if ($Path -eq $script:ProductFile) { throw 'SIMULATED PRODUCT WRITE FAILURE' }
            [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
        }
        Assert-Throws { Set-WorkbenchCss $script:CssFile ($script:CssBlock + 'changed') } '*SIMULATED PRODUCT WRITE FAILURE*'
        Assert-True ((Get-FileHash -LiteralPath $script:CssFile).Hash -eq $cssBefore) 'CSS rollback failed'
        Assert-True ((Get-FileHash -LiteralPath $script:ProductFile).Hash -eq $productBefore) 'Product rollback failed'
    }
    Test-Case 'font loading failure is recorded as failed, not successful' {
        Assert-Throws { Invoke-SetupStep 'Font failure test' { Assert-FontLoaded 0 'invalid.ttf' } } '*did not load font*'
        Assert-True ($script:StepResults[$script:StepResults.Count - 1].Status -eq 'Failed') 'Failure reported as success'
    }
    Test-Case 'font installer stops when Windows rejects a font' {
        # Fake native boundary; this test never registers fonts with Windows.
        Add-Type -TypeDefinition 'namespace Win32 { public static class FontNativeMethods { public static int AddFontResourceW(string path) { return 0; } } }'
        function Ensure-FontNativeMethods { }
        function New-ItemProperty { }
        function New-Item {
            param([string]$Path, [string]$ItemType, [switch]$Force)
            if ($Path -like 'HKCU:*') { return }
            Microsoft.PowerShell.Management\New-Item @PSBoundParameters
        }
        $font = New-Fixture 'fake-fonts\RejectedFont.ttf' 'not a real font'
        $FontsPath = Split-Path -Parent $font
        $SkipFonts = $false
        Assert-Throws { Install-CurrentUserFonts } '*Windows did not load font*'
    }
    Test-Case 'skipped and warning steps have distinct status' {
        Invoke-SetupStep 'Skip test' { throw 'MUST NOT RUN' } 'Explicitly skipped'
        Assert-True ($script:StepResults[$script:StepResults.Count - 1].Status -eq 'Skipped') 'Skip not recorded'
        Invoke-SetupStep 'Warning test' { Write-WarnLine 'simulated warning' }
        Assert-True ($script:StepResults[$script:StepResults.Count - 1].Status -eq 'Warning') 'Warning reported as success'
    }
    Test-Case 'reset matches exact user-font filenames, not broad families or system paths' {
        . (Join-Path $repoRoot 'scripts\Reset-VSCodeBeautyLab.ps1')
        $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        [void]$names.Add('Inter.ttc')
        $inventory = [pscustomobject]@{ FileNames = $names }
        foreach ($value in @('C:\Windows\Fonts\Inter.ttc', 'OtherInter.ttf', 'Inter.ttc')) {
            $property = [Management.Automation.PSNoteProperty]::new('Inter (TrueType)', $value)
            Assert-True (-not (Test-BeautyFontRegistryValue $property $inventory)) 'Unrelated font matched'
        }
        $property = [Management.Automation.PSNoteProperty]::new('Inter', (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts\Inter.ttc'))
        Assert-True (Test-BeautyFontRegistryValue $property $inventory) 'Expected current-user font did not match'
    }
    Test-Case 'reset preview performs no uninstall, backup, deletion or registry write' {
        $engine = (Get-Process -Id $PID).Path
        $reset = Join-Path $repoRoot 'scripts\Reset-VSCodeBeautyLab.ps1'
        $null = & $engine -NoProfile -File $reset -FontsPath (Join-Path $repoRoot 'fonts') -WhatIf
        Assert-True ($LASTEXITCODE -eq 0) 'Reset preview failed'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'VSCodeBeauty\Backups'))) 'Preview created a backup'
    }
    Test-Case 'reset retains registration when a font file cannot be deleted' {
        . (Join-Path $repoRoot 'scripts\Reset-VSCodeBeautyLab.ps1')
        $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        [void]$names.Add('Inter.ttc')
        $inventory = [pscustomobject]@{ FileNames = $names }
        function Test-Path { return $true }
        function Get-ItemProperty {
            return [pscustomobject]@{ 'Inter (TrueType)' = (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts\Inter.ttc') }
        }
        function Remove-ItemProperty { throw 'REGISTRY MUST NOT BE REMOVED' }
        Remove-BeautyFontRegistryValues $inventory
        Assert-True ($script:ResetWarnings -eq 1) 'Retained font was not reported'
    }
}
finally {
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ((Split-Path -Parent $resolved) -eq $expectedParent -and (Split-Path -Leaf $resolved) -like 'VSCodeBeautyTests-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    else { throw "Refusing to clean unexpected test directory: $resolved" }
}
Write-Host "Tests: $script:Passed passed, $script:Failed failed."
if ($script:Failed) { exit 1 }
