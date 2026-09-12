# VS Code Beauty One-Click

Windows 上的 VS Code 字体美化与配置迁移脚本。支持安装 VS Code、安装字体、恢复外部配置和插件，以及修补 workbench 界面字体。修补 CSS 后会同步更新 `product.json` 中对应的校验和。

**没有旧配置也能做基础美化。完整主题、图标、插件和布局需要你自己的外部 Profile；仓库不包含私人配置，也不提供完整外观预设。**

## 环境与验证范围

- Windows 10/11、VS Code Stable 桌面版。自动下载安装使用 x64 User Installer。
- 推荐使用 PowerShell 7，在仓库根目录执行下文命令。修改前保存文件并完全退出 VS Code；迁移流程可能强制结束 Code 进程。
- 2026-09-12 已在 Windows、PowerShell 7.6.5、VS Code 1.137.0 x64 上完成“已安装后的基础美化”。安装位置为 `D:\Microsoft VS Code`，脚本识别到了该版本的分版本资源子目录。
- 已核验 41 个字体文件及用户注册项、CSS 校验和、JSON 无 BOM 编码，用户确认基础美化成功。旧 Profile 迁移、重置及其他版本不在本次验证范围内。
- 默认 User Installer 安装到 `%LOCALAPPDATA%\Programs\Microsoft VS Code`。其他位置是否能识别，取决于脚本对 `code` 命令和候选目录的检测，不保证支持任意自定义目录。

## 包含多少字体

默认提供三套主要字体系列，共 **41 个字体文件**，不是只有三个文件：

| 字体 | 文件数 | 说明 |
| --- | ---: | --- |
| JetBrains Mono | 16 | 代码字体，包含不同字重和斜体 |
| JetBrains Mono NL | 16 | JetBrains Mono 的无连字版本 |
| Inter | 3 | 界面字体，包含字体集合和可变字体文件 |
| HarmonyOS Sans SC | 6 | 中文字体，包含不同字重 |
| **合计** | **41** | 文件数不等于字体系列数或可选样式数 |

默认使用仓库 `fonts/` 时会安装全部 41 个文件。外部字体来源的数量以对应目录为准。字体齐全不代表主题、图标、插件和布局也已恢复。

JetBrains Mono 和 Inter 使用 SIL Open Font License 1.1；HarmonyOS Sans Fonts 使用其自身许可协议，本仓库分发未修改字体。许可文本位于 `fonts/licenses/`。

## 开始前：备份并选择用途

下载或克隆仓库，打开 PowerShell 7，进入包含 `README.md`、`scripts/` 和 `fonts/` 的仓库根目录。

**配置和插件恢复采用镜像复制，会覆盖同名文件，并删除目标中源目录没有的文件。默认恢复不会先备份。** 自动识别和显式指定 Profile 都适用此行为。

关闭 VS Code 后，可先把当前用户配置和插件复制到仓库之外：

```powershell
$ErrorActionPreference = 'Stop'
$backupRoot = Join-Path ([Environment]::GetFolderPath('Desktop')) ("VSCode-Beauty-Backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $backupRoot | Out-Null
$userData = Join-Path $env:APPDATA 'Code'
$extensions = Join-Path $env:USERPROFILE '.vscode\extensions'
if (Test-Path -LiteralPath $userData) {
    Copy-Item -LiteralPath $userData -Destination (Join-Path $backupRoot 'user-data') -Recurse
}
if (Test-Path -LiteralPath $extensions) {
    Copy-Item -LiteralPath $extensions -Destination (Join-Path $backupRoot 'extensions') -Recurse
}
Write-Host "Backup: $backupRoot"
```

确认复制成功后再继续。这份备份只包含配置和插件；样式修补会在 CSS 和 `product.json` 旁分别生成 `.bak-时间戳` 文件。字体安装会覆盖当前用户字体目录中的同名文件，需要保留已有自定义版本时，应另外备份对应字体文件和注册项。迁移源、备份目录不要放在将被覆盖或清理的目录内。

## 用途一：已安装 VS Code，只做基础美化

没有旧 Profile，或希望保留当前主题、插件和布局时，执行：

```powershell
.\scripts\Install-VSCodeBeautyOneClick.ps1 `
  -SkipVSCodeInstall -SkipUserData -SkipExtensions
```

该命令安装字体、修补界面字体样式、创建桌面快捷方式，不执行配置和插件镜像恢复。若已安装 Todo Tree，脚本仍可能更新 `todo-tree.ripgrep` 设置，所以运行前仍应备份。

随后在 VS Code 命令面板打开 **Preferences: Open User Settings (JSON)**，把以下属性合并到现有设置对象。已有同名属性时修改原值，不要用整个示例覆盖现有设置：

```json
{
  "editor.fontFamily": "'JetBrains Mono', 'HarmonyOS Sans SC', Consolas, monospace",
  "editor.fontLigatures": true,
  "terminal.integrated.fontFamily": "'JetBrains Mono', 'HarmonyOS Sans SC', monospace"
}
```

这一步明确设置代码和终端字体。安装脚本不会自动写入这三个属性，CSS 也不能代替所有编辑器和终端字体配置。保存并完全退出、重新打开 VS Code。

预期效果：界面使用 Inter 和中文回退字体，代码与终端使用 JetBrains Mono 和中文回退字体。主题、图标、插件和布局取决于自己的配置，不会自动出现作者的完整外观。

如果尚未安装 VS Code，去掉 `-SkipVSCodeInstall`，保留两个跳过恢复的参数：

```powershell
.\scripts\Install-VSCodeBeautyOneClick.ps1 -SkipUserData -SkipExtensions
```

双击 `scripts\Run-OneClick-Beauty.cmd` 会使用 Windows PowerShell 执行默认流程，包括尝试自动识别 Profile。它不等同于上述明确跳过迁移的命令；本次验证使用 PowerShell 7。

## 用途二：迁移自己的完整配置和插件

先在源机器关闭 VS Code，再准备外部目录：

```text
E:\VSCodeBeautyProfile\
  user-data\       # 源机器 %APPDATA%\Code 的内容
  extensions\      # 源机器 %USERPROFILE%\.vscode\extensions 的内容
```

先备份目标机器的现有配置和插件，确认两个源目录完整且不为空，再显式指定路径。已安装 VS Code 时执行：

```powershell
.\scripts\Install-VSCodeBeautyOneClick.ps1 -SkipVSCodeInstall `
  -UserDataPath "E:\VSCodeBeautyProfile\user-data" `
  -ExtensionsPath "E:\VSCodeBeautyProfile\extensions"
```

未安装 VS Code 时去掉 `-SkipVSCodeInstall`。Profile 不需要重复携带仓库字体；使用其他字体目录可附加 `-FontsPath "E:\MyFonts"`。

迁移是文件复制，不保证跨机器的登录状态、绝对路径和包含本机组件的插件直接可用。迁移后逐项检查，按需重新登录、修改路径或重新安装不兼容插件。

### 自动识别与旧格式

不传源路径、也不跳过恢复时，脚本会从脚本目录、仓库目录、仓库父目录、当前工作目录，以及它们的 `profile`、`VSCodeBeautyProfile`、`VSCodeBeautySource`、`payload` 等子目录寻找来源。用户数据和插件分别识别，可能来自不同根目录；首次迁移推荐显式传参。

某类来源有多个候选时，脚本打印警告并跳过该类恢复，其他步骤仍继续。最终显示 `Done` 不代表全部迁移成功，应检查中间警告。

旧格式仍支持：

```powershell
.\scripts\Install-VSCodeBeautyOneClick.ps1 -PayloadPath "E:\VSCodeBeautySource"
```

该目录可包含 `user-data/`、`extensions/`、`fonts/`，也可使用其下的 `payload/`。字体优先级为显式 `-FontsPath`、payload 的 `fonts/`、仓库 `fonts/`。旧格式同样需要先备份。

## 用途三：VS Code 更新后，只修复样式

更新可能替换 workbench CSS。字体已经安装时，执行：

```powershell
.\scripts\Install-VSCodeBeautyOneClick.ps1 `
  -SkipVSCodeInstall -SkipUserData -SkipExtensions -SkipFonts
```

此命令跳过安装、字体重装及配置和插件镜像恢复，重新应用 CSS 并同步校验和。脚本仍会创建快捷方式、执行验证，并可能更新 Todo Tree 路径。完成后重启 VS Code。不要为了修复样式而重新导入旧 Profile。

## 其他参数与实验重置

| 参数 | 实际行为 |
| --- | --- |
| `-SkipVSCodeInstall` | 跳过 VS Code 安装 |
| `-SkipUserData` / `-SkipExtensions` | 分别跳过对应镜像恢复 |
| `-SkipFonts` | 跳过字体安装，其他步骤仍执行 |
| `-SkipWorkbenchCss` | 跳过 CSS 修补，其他步骤仍执行 |
| `-CleanFirst` | 先将标准位置的用户数据、插件及用户版安装目录移到桌面备份目录，再继续流程 |
| `-ForceDownload` | 强制重新下载安装包并执行安装 |

`-CleanFirst` 不是普通的“备份开关”，也不是基础美化所必需的步骤；它会先清理，再校验后续来源。不要把它与 `-SkipVSCodeInstall` 当作“保留安装只备份”组合使用，也不要让源 Profile 位于待清理目录中。

**`Reset-VSCodeBeautyLab.ps1` 仅供可丢弃的测试环境使用，不是日常美化、字体卸载或回滚工具。** 当前实现会尝试卸载 VS Code、移走用户数据和整个 `.vscode` 目录，并尝试清理用户及系统字体目录、HKCU 及 HKLM 字体注册项。管理员运行可能影响其他用户；非管理员运行也会尝试这些操作，失败时仅打印警告。它没有导出字体注册项备份，不能保证完整回滚。

实验前先在独立测试环境创建完整快照，再阅读重置脚本。`Install-FreshVSCodeForLab.ps1` 用于实验环境重新下载安装，不属于日常使用步骤。

## 验证与恢复

- 默认字体来源应报告 41 个文件；检查方法见 [字体安装说明](docs/font-installation.md)。
- 检查 CSS 备份路径、`Updated product checksum` 和所有警告，再重启 VS Code。
- 回退样式时退出 VS Code，将同一次运行、同一 VS Code 版本对应的 CSS 和 `product.json` 备份一起恢复；不要把旧版文件覆盖到更新后的安装目录。
- 配置和插件恢复方法见 [排错文档](docs/troubleshooting.md)。恢复 CSS 不会卸载已安装字体。

不要将自己的 Profile、登录状态、历史记录或其他私人字体提交到仓库。
