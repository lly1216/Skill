<#
.SYNOPSIS
    把 engineering-mentor 技能打包成可上传的 ZIP（engineering-mentor-<版本>.zip）。

.DESCRIPTION
    面向“只能上传 ZIP”的聊天类工具（claude.ai、Kimi 等）：这些工具只需要技能本体，
    不需要仓库级的 README / LICENSE / CHANGELOG / .gitignore / AGENTS.md，也不需要安装脚本。
    上传菜单路径与体积上限以各工具官方说明为准（此处标「待核实」）。

    ZIP 内容结构：根下就是 engineering-mentor/ 目录，其中第一层直接是 SKILL.md，
    符合 Agent Skills 标准对“一个技能目录 + SKILL.md”的要求。
    来源：https://agentskills.io 、https://code.claude.com/docs/en/skills

    排除项（相对技能根）：
      reference/00-source-requirements.md、reference/12-projects-context.md（私有文件）
      .git、install/、README.md、LICENSE、CHANGELOG.md、.gitignore、AGENTS.md
      以及常见的 .DS_Store / Thumbs.db / desktop.ini

    版本号来源（按顺序取第一个命中的）：
      1. -Version 参数
      2. CHANGELOG.md 中第一处 x.y.z
      3. SKILL.md 的 frontmatter 里 version: 字段
      4. 兜底 0.1.0
      ※ 仓库的版本号以 CHANGELOG.md 与 git tag 为准（由 Lead 维护），
        无法自动读取时请在调用时显式传 -Version。

    兼容性：Windows PowerShell 5.1 与 PowerShell 7 均可运行（未使用 7 专属语法）。
    临时目录：打包期间会在输出目录下建一个 .zipstaging-<进程号> 目录，结束时（含失败）自动删除。

.EXAMPLE
    # 在仓库根（技能目录）执行：输出到当前目录，版本自动推断
    powershell -ExecutionPolicy Bypass -File .\install\make-skill-zip.ps1

.EXAMPLE
    # 指定版本与输出目录
    pwsh -File .\install\make-skill-zip.ps1 -Version 0.2.0 -OutDir .\dist

.EXAMPLE
    # 从别处打某个技能目录
    pwsh -File .\install\make-skill-zip.ps1 -Source "C:\src\engineering-mentor"
#>

[CmdletBinding()]
param(
    # 技能源目录（应直接包含 SKILL.md）。默认：本脚本所在目录的上级目录
    [string]$Source = '',

    # 输出目录，默认当前工作目录
    [string]$OutDir = (Get-Location).ProviderPath,

    # 版本号；留空则自动推断
    [string]$Version = ''
)

$ErrorActionPreference = 'Stop'

# ---- 1. 解析源目录 -----------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Source)) {
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        throw '无法自动推断源目录（未拿到脚本路径）。请显式指定 -Source <技能目录>。'
    }
    $Source = Split-Path -Parent $PSScriptRoot
}
if (-not (Test-Path -LiteralPath $Source)) {
    throw "源目录不存在：$Source"
}
$Source = (Resolve-Path -LiteralPath $Source).ProviderPath

if (-not (Test-Path -LiteralPath (Join-Path $Source 'SKILL.md') -PathType Leaf)) {
    throw "源目录里找不到 SKILL.md，这不是一个 Agent Skills 技能目录：$Source"
}

$skillName = Split-Path -Leaf $Source

# ---- 2. 解析版本号 -----------------------------------------------------------
function Get-VersionFromChangelog {
    param([string]$Root)
    $changelog = Join-Path $Root 'CHANGELOG.md'
    if (-not (Test-Path -LiteralPath $changelog -PathType Leaf)) { return '' }
    $match = Select-String -LiteralPath $changelog -Pattern '(\d+\.\d+\.\d+)' | Select-Object -First 1
    if ($null -eq $match) { return '' }
    return $match.Matches[0].Groups[1].Value
}

function Get-VersionFromSkillMd {
    param([string]$Root)
    $skillMd = Join-Path $Root 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillMd -PathType Leaf)) { return '' }
    $match = Select-String -LiteralPath $skillMd -Pattern '^version:\s*[''"]?([0-9]+\.[0-9]+\.[0-9]+)' | Select-Object -First 1
    if ($null -eq $match) { return '' }
    return $match.Matches[0].Groups[1].Value
}

$versionSource = '-Version 参数'
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = Get-VersionFromChangelog -Root $Source
    $versionSource = 'CHANGELOG.md'
}
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = Get-VersionFromSkillMd -Root $Source
    $versionSource = 'SKILL.md frontmatter'
}
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = '0.1.0'
    $versionSource = '兜底默认值（未在 CHANGELOG.md / SKILL.md 找到版本号）'
}

# 版本号会进文件名，先挡住路径穿越与非法字符
$Version = $Version.Trim()
if ($Version -match '[\\/:*?"<>|]' -or $Version -match '\.\.') {
    throw "版本号含有不适合做文件名的字符：$Version（请传纯 x.y.z 形式）"
}

# ---- 3. 输出路径 -------------------------------------------------------------
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}
$OutDir = (Resolve-Path -LiteralPath $OutDir).ProviderPath

$zipName = '{0}-{1}.zip' -f $skillName, $Version
$zipPath = Join-Path $OutDir $zipName

if (Test-Path -LiteralPath $zipPath) {
    Write-Host ("已存在同名 ZIP，将被覆盖：{0}" -f $zipPath)
    Remove-Item -LiteralPath $zipPath -Force
}

# ---- 4. 排除规则 -------------------------------------------------------------
$excludeRelFiles = @(
    'reference/00-source-requirements.md',
    'reference/12-projects-context.md',
    'README.md',
    'LICENSE',
    'CHANGELOG.md',
    '.gitignore',
    'AGENTS.md',
    '.DS_Store',
    'Thumbs.db',
    'desktop.ini'
)
# 目录级排除：.git（版本库元数据）与 install/（安装脚本，工具用不到）
$excludeDirs = @('.git', 'install')

function Test-IsExcluded {
    param([string]$FullName)

    foreach ($dirName in $excludeDirs) {
        if ($FullName -match ('(^|[\\/])' + [regex]::Escape($dirName) + '([\\/]|$)')) {
            return $true
        }
    }

    $rel = $FullName.Substring($Source.Length).TrimStart([char]'\', [char]'/')
    $relNorm = $rel.Replace('\', '/')
    foreach ($item in $excludeRelFiles) {
        if ($relNorm -eq $item) { return $true }
    }
    return $false
}

# ---- 5. 收集要打包的文件 -----------------------------------------------------
$allFiles = @(Get-ChildItem -LiteralPath $Source -Recurse -File -Force)
$include = New-Object System.Collections.ArrayList
$excludedCount = 0

foreach ($file in $allFiles) {
    if (Test-IsExcluded -FullName $file.FullName) {
        $excludedCount++
        continue
    }
    [void]$include.Add($file)
}

# 按相对路径排序，清单输出才稳定
$entries = @()
foreach ($file in $include) {
    $rel = $file.FullName.Substring($Source.Length).TrimStart([char]'\', [char]'/')
    $entries += [pscustomobject]@{
        FullName = $file.FullName
        Rel      = $rel.Replace('\', '/')
    }
}
$entries = @($entries | Sort-Object -Property Rel)

if ($entries.Count -eq 0) {
    throw "没有任何文件可打包（排除规则把全部文件都排除了）：$Source"
}

# ---- 6. 打包（用暂存目录保证 ZIP 内结构与排除项准确） ------------------------
$stagingRoot = Join-Path $OutDir ('.zipstaging-' + $PID)
$stagingSkill = Join-Path $stagingRoot $skillName

try {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $stagingSkill | Out-Null

    foreach ($entry in $entries) {
        $destPath = Join-Path $stagingSkill $entry.Rel
        $destDir = Split-Path -Parent $destPath
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Force -Path $destDir | Out-Null
        }
        Copy-Item -LiteralPath $entry.FullName -Destination $destPath -Force
    }

    Compress-Archive -Path $stagingSkill -DestinationPath $zipPath -CompressionLevel Optimal -Force
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}

if (-not (Test-Path -LiteralPath $zipPath)) {
    throw "打包失败，没有生成 ZIP：$zipPath"
}

$zipItem = Get-Item -LiteralPath $zipPath
$sizeKb = [math]::Round($zipItem.Length / 1KB, 1)

# ---- 7. 结果与清单 -----------------------------------------------------------
Write-Host ''
Write-Host '打包完成。'
Write-Host ("  ZIP 路径 : {0}" -f $zipItem.FullName)
Write-Host ("  大小     : {0} KB" -f $sizeKb)
Write-Host ("  版本     : {0}（来源：{1}）" -f $Version, $versionSource)
Write-Host ("  打包文件 : {0} 个；已排除 {1} 个（私有文件、.git、install/、README/LICENSE/CHANGELOG/.gitignore/AGENTS.md）" -f $entries.Count, $excludedCount)
Write-Host ''
Write-Host ("内容清单（前 20 项，共 {0} 项，路径相对于 ZIP 根）：" -f $entries.Count)

$shown = 0
foreach ($entry in $entries) {
    if ($shown -ge 20) { break }
    Write-Host ("  {0}/{1}" -f $skillName, $entry.Rel)
    $shown++
}
if ($entries.Count -gt 20) {
    Write-Host ("  ... 其余 {0} 项未列出" -f ($entries.Count - 20))
}

Write-Host ''
Write-Host "上传到只接受 ZIP 的工具（claude.ai 等）时选择上面的 ZIP 文件即可；具体菜单路径与体积上限请以该工具官方说明为准（待核实）。"
Write-Host ''
