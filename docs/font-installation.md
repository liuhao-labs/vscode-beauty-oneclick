# Windows 字体命令行安装与卸载

本项目采用“当前用户字体安装”方案。默认字体来源是仓库的 `fonts/`，也可以通过 `-FontsPath` 指向其它字体目录。

- 字体文件复制到 `%LOCALAPPDATA%\Microsoft\Windows\Fonts`
- 注册表写入 `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts`
- 调用 GDI 的 `AddFontResourceW`
- 通过 `WM_FONTCHANGE` 通知正在运行的应用刷新字体列表

以上描述的是主安装脚本 `Install-VSCodeBeautyOneClick.ps1`，它不写入 `C:\Windows\Fonts` 或 HKLM。实验重置脚本的处理范围不同，见下文。

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

脚本的安装计数不验证 `AddFontResourceW` 的返回值；看到数量成功后，还应检查实际显示效果。需要保留已安装的自定义同名字体版本时，应先备份对应文件和注册项。

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

当前 `Reset-VSCodeBeautyLab.ps1` 会尝试处理用户字体目录和 `C:\Windows\Fonts`，以及 HKCU 和 HKLM 字体注册项。文件按来源文件名匹配，注册项还会按内置字体系列名称匹配，可能涉及之前已安装的同系列字体。文件删除前尝试备份，但注册项没有导出备份；管理员运行可能影响其他用户。它还会卸载 VS Code 并移走配置，只适合可丢弃、有快照的测试环境。

## 官方依据

- [Font Installation and Deletion](https://learn.microsoft.com/en-us/windows/win32/gdi/font-installation-and-deletion)
- [AddFontResourceW](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-addfontresourcew)
- [RemoveFontResourceW](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-removefontresourcew)
- [WM_FONTCHANGE](https://learn.microsoft.com/en-us/windows/win32/gdi/wm-fontchange)
