# Windows 字体命令行安装与卸载

本项目采用“当前用户字体安装”方案。默认字体来源是仓库的 `fonts/`，也可以通过 `-FontsPath` 指向其它字体目录。

- 字体文件复制到 `%LOCALAPPDATA%\Microsoft\Windows\Fonts`
- 注册表写入 `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts`
- 调用 GDI 的 `AddFontResourceW`
- 通过 `WM_FONTCHANGE` 通知正在运行的应用刷新字体列表

主安装脚本和实验重置脚本都只处理当前用户字体，不写入 `C:\Windows\Fonts` 或 HKLM。

## 数量与用途

仓库默认提供 41 个字体文件：JetBrains Mono 16 个、JetBrains Mono NL 16 个、Inter 3 个、HarmonyOS Sans SC 6 个。NL 是无连字版本，同一系列还包含不同字重、斜体、字体集合或可变字体，因此文件数不等于字体系列数或可选样式数。

界面使用 Inter 和 HarmonyOS Sans SC，代码和终端可使用 JetBrains Mono 和 HarmonyOS Sans SC。字体齐全不代表主题、图标、插件和布局也已恢复。

来源优先级：显式 `-FontsPath` > payload 的 `fonts/` > 仓库 `fonts/`。外部来源的文件数量可以与仓库不同。

## 安装

核心流程在 `Install-VSCodeBeautyOneClick.ps1` 中：

1. 枚举字体来源目录下的 `.ttf`、`.ttc`、`.otf`
2. 复制到当前用户字体目录，同名文件会被覆盖
3. 根据文件名生成注册项名称（当前实现没有读取字体内部 Family 名称）
4. 写入 HKCU Fonts 注册表项
5. 调用 `AddFontResourceW`
6. 广播 `WM_FONTCHANGE`

现在会检查 `AddFontResourceW` 的返回值、字体文件哈希和注册路径，任一失败就停止并报告失败。相同内容的字体文件不重复覆盖；安装前自动备份已有同名文件和注册项到本次备份目录的 `fonts/`、`fonts-before.xml`。系统加载成功后，仍应在应用中检查实际显示效果。

## 检查是否遗漏

在仓库根目录运行以下只读检查，对比仓库字体和用户目录中的文件哈希：

```powershell
$targetRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
$fonts = @(Get-ChildItem -LiteralPath '.\fonts' -File |
    Where-Object { $_.Extension -in @('.ttf', '.ttc', '.otf') })
$results = foreach ($font in $fonts) {
    $target = Join-Path $targetRoot $font.Name
    $exists = Test-Path -LiteralPath $target
    $matches = $false
    if ($exists) {
        $matches = (Get-FileHash -LiteralPath $font.FullName).Hash -eq (Get-FileHash -LiteralPath $target).Hash
    }
    [pscustomobject]@{ Font = $font.Name; Installed = $exists; SameFile = $matches }
}
$results | Format-Table -AutoSize
Write-Host "Repository font files: $($fonts.Count)"
```

默认来源应有 41 行，`Installed` 和 `SameFile` 均为 `True`。随后检查 HKCU 字体注册项，并在 VS Code 中确认中英文、粗体和斜体显示正常。已经打开的应用可能需要重启才能识别字体。

编辑器和终端还需要明确设置 `editor.fontFamily`、`terminal.integrated.fontFamily`；代码连字由 `editor.fontLigatures` 控制。安装脚本不会自动写入这三个属性，示例见 [README](../README.md)。

## 卸载与实验重置的区别

仅想移除字体时，应通过 Windows 字体设置确认并卸载所需字体，不要使用实验重置脚本作为字体卸载工具。

`Reset-VSCodeBeautyLab.ps1` 仅处理当前用户字体目录和 HKCU 注册项，不操作系统字体或 HKLM。按清单中的精确文件名和用户字体路径匹配，不再仅凭系列名称删除。它会先备份匹配字体及注册值到 `fonts-before/`、`fonts-registry-before.xml`；文件删除失败时保留注册项，汇总为警告。XML 备份保存值名称、类型和原值，用于人工核对恢复，不是可双击导入的 `.reg` 文件。

重置还会卸载标准位置的用户版 VS Code、移走配置和插件，只适合独立测试环境。可使用 `-WhatIf` 先预览范围。安装与重置都不强制关闭正在运行的 VS Code。

## 官方依据

- [Font Installation and Deletion](https://learn.microsoft.com/en-us/windows/win32/gdi/font-installation-and-deletion)
- [AddFontResourceW](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-addfontresourcew)
- [RemoveFontResourceW](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-removefontresourcew)
- [WM_FONTCHANGE](https://learn.microsoft.com/en-us/windows/win32/gdi/wm-fontchange)
