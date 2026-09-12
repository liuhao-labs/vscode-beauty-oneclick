# Troubleshooting

## VS Code 提示安装损坏

现象：

```text
Your Code installation appears to be corrupt. Please reinstall.
```

原因通常不是 VS Code 真坏了，而是修改了 `workbench.desktop.main.css` 后，没有同步更新 `product.json` 中记录的 SHA256 校验和。

本项目的 `Install-VSCodeBeautyOneClick.ps1` 在修补 CSS 后会重新计算 hash 并写回 `product.json`，随后核验两者匹配。这处理的是该 CSS 文件的校验问题，不能保证消除所有安装损坏提示。如果你手动改了 CSS，请使用下文“VS Code 更新后样式消失”中的跳过迁移命令。若日志没有 `Updated product checksum`，检查失败步骤和安装路径；修补失败会尝试恢复本次修改前的 CSS 和校验文件。

需要回退时，退出 VS Code，把同一次运行、同一版本的 CSS 和 `product.json` 备份一起恢复。不要将旧版本的备份覆盖到更新后的安装目录。

## Remote-SSH 报 JSON.parse 错误

现象：

```text
Could not establish connection to "...": Unexpected token '﻿', "﻿{
    "n"... is not valid JSON
```

这通常不是远端 SSH 主机的问题。已确认的一种原因是本机 VS Code 安装目录里的 `resources\app\product.json` 被保存成了 UTF-8 with BOM。Remote-SSH 会直接 `JSON.parse` 这个文件，遇到文件头的 BOM 就会在真正连接远端前失败。

本项目脚本已改为 UTF-8 without BOM 写入 `product.json`、`settings.json` 和 workbench CSS。旧版本脚本造成的问题可以这样修：

```powershell
# 按实际安装位置修改；例如 D:\Microsoft VS Code
$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code'
$products = @(Get-ChildItem -LiteralPath $installRoot -Recurse -Filter product.json -File |
    Where-Object { $_.FullName -match '\\resources\\app\\product\.json$' })
if ($products.Count -ne 1) {
    throw '未找到唯一的应用 product.json，请先确认当前版本的资源目录。'
}
$product = $products[0]
$bytes = [IO.File]::ReadAllBytes($product.FullName)
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    Copy-Item -LiteralPath $product.FullName -Destination "$($product.FullName).bak-remove-bom"
    [IO.File]::WriteAllBytes($product.FullName, $bytes[3..($bytes.Length - 1)])
}
```

处理后 reload VS Code window，或完全关闭 VS Code 再打开。

## 字体仍然不对

默认是三套主要字体系列、41 个文件，不是只有三个文件。清单和逐文件检查见 [字体安装说明](font-installation.md)。安装字体之后，还要按 [README](../README.md) 合并编辑器和终端的字体设置；主题、图标、插件和布局需要单独配置或迁移。

先确认三件事：

```powershell
# 当前用户字体文件是否存在
Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Fonts" -Include *.ttf,*.ttc,*.otf -Recurse

# HKCU Fonts 是否注册
Get-ItemProperty "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"

# VS Code settings.json 中 editor.fontFamily 是否正确
Get-Content "$env:APPDATA\Code\User\settings.json"
```

如果刚安装完字体，已经打开的应用可能不会立刻刷新。脚本会广播 `WM_FONTCHANGE`，但少数应用仍可能需要重新打开。

## Todo Tree 找不到 ripgrep

部分 VS Code 版本或插件组合下，Todo Tree 无法自动定位 VS Code 自带的 `rg.exe`。脚本会在 VS Code 安装目录下查找 `@vscode\ripgrep-*`，并把结果写入：

```json
{
  "todo-tree.ripgrep": "..."
}
```

如果 VS Code 更新后路径变了，可运行下文跳过迁移的样式修复命令，它仍会尝试更新 Todo Tree 路径。`settings.json` 不是脚本所用 PowerShell 版本可解析的 JSON 时，此步骤会警告并跳过；此时在 VS Code 设置中手动修改 `todo-tree.ripgrep`，不要为了一个路径替换整个设置文件。

## VS Code 更新后样式消失

VS Code 更新可能替换安装目录中的 workbench CSS。先保存文件、退出 VS Code；字体已安装时，在仓库根目录运行：

```powershell
.\scripts\Install-VSCodeBeautyOneClick.ps1 `
  -SkipVSCodeInstall -SkipUserData -SkipExtensions -SkipFonts
```

该命令不重新导入旧 Profile，避免覆盖更新后自己修改的设置和插件。脚本仍会处理快捷方式、验证及可能的 Todo Tree 路径更新，完成后重新打开 VS Code。

## 配置恢复后，原来的设置或插件不见了

恢复仍使用 `robocopy /MIR` 镜像复制，源目录没有的目标文件会被删除。现在默认先自动备份，备份失败不继续。查看汇总中的 `Backup` 路径，默认位于 `%LOCALAPPDATA%\VSCodeBeauty\Backups`。

已有备份时，关闭 VS Code，将当前 `%APPDATA%\Code` 和 `%USERPROFILE%\.vscode\extensions` 分别改名保存，避免丢掉迁移后的新增内容，再把备份中的 `user-data` 和 `extensions` 分别复制回这两个原路径。不要在原目标上直接合并，否则可能留下多余文件。若备份中本来没有某个目录，不要凭空创建“原始备份”。

使用过 `-CleanFirst` 时，查看本次备份目录下的 `cleaned/`，其中目录名经过路径转换，不是常规备份的 `user-data` / `extensions` 命名。旧版脚本的清理备份可能仍在桌面。如果使用旧版镜像恢复且没有任何备份，脚本本身不能撤销已删除的数据。

## 样式修补一直不结束

旧版在 CSS 仅剩开始标记时可能无法退出。新版会在修改前检查缺失、嵌套或错序标记，并立即报错，不再循环重试。遇到标记错误时，先确认 VS Code 版本，恢复对应的原始 CSS 和 `product.json`，再运行样式修复命令。

## 是否需要先运行 Reset

不需要。基础美化和更新后修复都不需要 `Reset-VSCodeBeautyLab.ps1` 或 `-CleanFirst`。新版 Reset 仅处理当前用户范围，但仍会卸载标准位置的用户版 VS Code 并移走配置、插件，只适合独立测试环境。先使用 `-WhatIf` 查看范围。

## 提示来源不完整、重叠或参数冲突

新版在安装、清理和恢复前进行检查。不要用空目录作为迁移源，不要把源放在目标内，也不要把备份位置设在源或目标内。目录链接和联接不参与镜像复制。只恢复一类内容时必须明确跳过另一类；多个候选不会自动选择。`-CleanFirst` 要求两类有效来源，不能与跳过安装或跳过任一恢复步骤组合。

## 如何判断执行是否成功

查看步骤表：`Success` 为完成，`Skipped` 为跳过，`Warning` 为完成但有需要处理的问题，`Failed` 为失败并停止。退出码分别是 `0`（完成，允许跳过）、`1`（失败）、`2`（有警告）。失败并不代表之前所有步骤都自动撤销；配置、插件和字体可从已输出的备份位置恢复，CSS 写入失败会尝试恢复该对文件。

## 私人 Profile 不要提交到 Git

VS Code 用户数据可能包含登录状态、扩展缓存、机器路径、历史记录等私人内容。请把自己的 Profile 放在仓库外部，通过 `-UserDataPath` 和 `-ExtensionsPath` 传给脚本。

仓库已经包含本项目使用的公共字体和对应许可证；其它私人字体不要提交到 Git。
