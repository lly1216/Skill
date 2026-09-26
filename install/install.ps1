<#
.SYNOPSIS
    把 engineering-mentor 技能安装到某个支持 Agent Skills 标准的技能目录。

.DESCRIPTION
    Agent Skills 标准规定：一个技能 = 一个目录，目录里必须有 SKILL.md（YAML frontmatter 含
    name / description），技能目录下可放支持文件（本技能的 reference/ 与 templates/）。
    Claude Code 的技能目录为 ~/.claude/skills/<skill-name>/SKILL.md（个人）或
    .claude/skills/<skill-name>/SKILL.md（项目）；其他遵循该标准的工具同理。
    来源：https://agentskills.io 、https://code.claude.com/docs/en/skills

    本脚本只做“复制”，绝不删除目标目录里已有的任何东西（避免误删你自己的学习档案）。
    已存在的文件默认跳过并逐条提示；要覆盖请加 -Force。
    复制时排除两个私有文件（reference/00-source-requirements.md、
    reference/12-projects-context.md）以及 .git 与 install/（脚本自身不需要被安装）。

    兼容性：Windows PowerShell 5.1 与 PowerShell 7 均可运行（未使用 7 专属语法）。

.EXAMPLE
    # 默认：复制到 ~/.claude/skills/engineering-mentor（源 = 本脚本的上级目录）
    powershell -ExecutionPolicy Bypass -File .\install\install.ps1

.EXAMPLE
    # 安装到 DeepSeek Harness 的全局技能目录（DSH_HOME 默认 ~/.dsh）
    powershell -ExecutionPolicy Bypass -File .\install\install.ps1 -Target "$HOME\.dsh\skills\engineering-mentor"

.EXAMPLE
    # 安装到某个项目的 .claude/skills 下，并覆盖同名旧文件（不删多余文件）
    pwsh -File .\install\install.ps1 -Target "C:\work\my-app\.claude\skills\engineering-mentor" -Force
#>

[CmdletBinding()]
param(
    # 目标技能目录。默认：~/.claude/skills/engineering-mentor
    [string]$Target = (Join-Path $HOME '.claude/skills/engineering-mentor'),

    # 技能源目录（应直接包含 SKILL.md）。默认：本脚本所在目录的上级目录
    [string]$Source = '',

    # 覆盖已存在的同名文件（默认跳过；无论如何都不删除目标里的其他文件）
    [switch]$Force
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

$skillMd = Join-Path $Source 'SKILL.md'
if (-not (Test-Path -LiteralPath $skillMd -PathType Leaf)) {
    throw "源目录里找不到 SKILL.md，这不是一个 Agent Skills 技能目录：$Source"
}

# ---- 2. 目标目录 -------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Target)) {
    throw '目标路径为空。请用 -Target <目录> 指定技能目录。'
}
# 相对路径按当前工作目录解析；不做 Resolve-Path（目标可能还不存在）
if (-not [System.IO.Path]::IsPathRooted($Target)) {
    $Target = Join-Path (Get-Location).ProviderPath $Target
}
$Target = $Target.TrimEnd([char]'\', [char]'/')
if ([string]::IsNullOrWhiteSpace($Target)) {
    throw '目标路径解析后为空，请检查 -Target 参数。'
}

# ---- 3. 复制前确认 -----------------------------------------------------------
Write-Host ''
Write-Host 'engineering-mentor 技能安装'
Write-Host ("  源目录 : {0}" -f $Source)
Write-Host ("  目标   : {0}" -f $Target)
Write-Host '  模式   : 仅复制，不删除目标目录中已有的任何文件'
Write-Host ''

if (-not $Force) {
    $answer = Read-Host '将从上面的“源目录”复制到“目标”，继续吗？[y/N]'
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host '已取消，未做任何修改。'
        exit 0
    }
}

if (-not (Test-Path -LiteralPath $Target)) {
    New-Item -ItemType Directory -Force -Path $Target | Out-Null
    Write-Host ("已创建目标目录：{0}" -f $Target)
}

# ---- 4. 排除规则 -------------------------------------------------------------
# 两个私有文件：只留在本地，不随安装/发布分发
$excludeRel = @(
    'reference/00-source-requirements.md',
    'reference/12-projects-context.md'
)
# 目录级排除：.git（版本库元数据）与 install/（安装脚本自身）
$excludeDirs = @('.git', 'install')

$sep = [System.IO.Path]::DirectorySeparatorChar

function Test-IsExcluded {
    param([string]$FullName)

    # 目录名排除（对全文任一段匹配，避免遗漏嵌套 .git）
    foreach ($dirName in $excludeDirs) {
        if ($FullName -match ('(^|[\\/])' + [regex]::Escape($dirName) + '([\\/]|$)')) {
            return $true
        }
    }

    # 相对源目录的路径排除
    $rel = $FullName.Substring($Source.Length).TrimStart([char]'\', [char]'/')
    $relNorm = $rel.Replace('\', '/')
    foreach ($item in $excludeRel) {
        if ($relNorm -eq $item) { return $true }
    }
    return $false
}

# ---- 5. 执行复制（只新增/覆盖，不删除） --------------------------------------
$files = @(Get-ChildItem -LiteralPath $Source -Recurse -File -Force)

$copied = 0
$skippedExisting = 0
$skippedExcluded = 0
$existingNames = @()

foreach ($file in $files) {
    if (Test-IsExcluded -FullName $file.FullName) {
        $skippedExcluded++
        continue
    }

    $rel = $file.FullName.Substring($Source.Length).TrimStart([char]'\', [char]'/')
    $destPath = Join-Path $Target $rel
    $destDir = Split-Path -Parent $destPath

    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    }

    if ((Test-Path -LiteralPath $destPath) -and (-not $Force)) {
        $skippedExisting++
        $existingNames += $rel.Replace('\', '/')
        continue
    }

    Copy-Item -LiteralPath $file.FullName -Destination $destPath -Force
    $copied++
}

# ---- 6. 结果与提示 -----------------------------------------------------------
$totalFiles = @(Get-ChildItem -LiteralPath $Target -Recurse -File -Force).Count

Write-Host ''
Write-Host '安装完成。'
Write-Host ("  目标路径 : {0}" -f $Target)
Write-Host ("  本次写入 : {0} 个文件" -f $copied)
Write-Host ("  目标文件 : {0} 个文件（含此前已存在的）" -f $totalFiles)
Write-Host ("  已排除   : {0} 个文件（两个私有 reference 文件、.git、install/）" -f $skippedExcluded)

if ($skippedExisting -gt 0) {
    Write-Host ("  已跳过   : {0} 个同名文件（目标里已存在，未覆盖）" -f $skippedExisting)
    foreach ($name in $existingNames) {
        Write-Host ("             {0}" -f $name)
    }
    Write-Host '  提示     : 要覆盖这些旧文件，请重新运行并加 -Force；本脚本不会删除其他文件。'
}

Write-Host ''
Write-Host '请重启工具或新开一个会话：技能列表里应出现 engineering-mentor。'
Write-Host '若未出现，请确认目标目录下直接存在 SKILL.md（即 <目标>/SKILL.md），且 frontmatter 里有 name 与 description。'
Write-Host ''
