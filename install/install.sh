#!/usr/bin/env bash
#
# install.sh —— 把 engineering-mentor 技能安装到某个支持 Agent Skills 标准的技能目录。
#
# 用途
#   Agent Skills 标准规定：一个技能 = 一个目录，目录里必须有 SKILL.md（YAML frontmatter 含
#   name / description），技能目录下可放支持文件（本技能的 reference/ 与 templates/）。
#   Claude Code 的技能目录为 ~/.claude/skills/<skill-name>/SKILL.md（个人）或
#   .claude/skills/<skill-name>/SKILL.md（项目）；其他遵循该标准的工具同理。
#   来源：https://agentskills.io 、https://code.claude.com/docs/en/skills
#
# 行为
#   只复制，不删除目标目录中已有的任何文件（避免误删你自己的学习档案与项目上下文）。
#   优先使用 rsync -a --exclude（增量、可续传）；系统没有 rsync 时退化为 cp -R，并在
#   复制后删除本应排除的路径，同时打印警告。
#
# 用法示例（Linux / macOS Bash）
#   bash install/install.sh
#   # 默认目标：~/.claude/skills/engineering-mentor；默认源：本脚本的上级目录
#
#   bash install/install.sh --target "$HOME/.dsh/skills/engineering-mentor"
#   # DeepSeek Harness 全局技能目录（DSH_HOME 默认 ~/.dsh）
#
#   bash install/install.sh --target "$PWD/.claude/skills/engineering-mentor" --force
#   # 安装到项目内；--force 跳过确认（仍不删除目标里的其他文件）
#
#   bash install/install.sh --source /opt/src/engineering-mentor --target /srv/skills/engineering-mentor
#

set -euo pipefail

# ---- 参数解析 ---------------------------------------------------------------
target="$HOME/.claude/skills/engineering-mentor"
source_dir=""
force=0

usage() {
    cat <<'EOF'
用法: bash install.sh [--target <目录>] [--source <目录>] [--force] [--help]

  --target <目录>  目标技能目录（默认: ~/.claude/skills/engineering-mentor）
  --source <目录>  技能源目录，须直接包含 SKILL.md（默认: 本脚本所在目录的上级）
  --force          跳过复制前确认；覆盖同名文件（仍不删除目标里的其他文件）
  --help, -h       显示本帮助

排除项: reference/00-source-requirements.md、reference/12-projects-context.md（私有文件）、
        .git、install/
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --target)
            if [ "$#" -lt 2 ]; then
                echo "错误：--target 后面缺少目录参数。" >&2
                exit 2
            fi
            target="$2"
            shift 2
            ;;
        --source)
            if [ "$#" -lt 2 ]; then
                echo "错误：--source 后面缺少目录参数。" >&2
                exit 2
            fi
            source_dir="$2"
            shift 2
            ;;
        --force|-f)
            force=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --target=*)
            target="${1#--target=}"
            shift
            ;;
        --source=*)
            source_dir="${1#--source=}"
            shift
            ;;
        *)
            echo "错误：未知参数 $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# ---- 解析源目录 -------------------------------------------------------------
if [ -z "$source_dir" ]; then
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    source_dir="$(cd -- "$script_dir/.." && pwd)"
fi

if [ ! -d "$source_dir" ]; then
    echo "错误：源目录不存在：$source_dir" >&2
    exit 1
fi
source_dir="$(cd -- "$source_dir" && pwd)"

if [ ! -f "$source_dir/SKILL.md" ]; then
    echo "错误：源目录里找不到 SKILL.md，这不是一个 Agent Skills 技能目录：$source_dir" >&2
    exit 1
fi

# ---- 目标目录 ---------------------------------------------------------------
case "$target" in
    "~") target="$HOME" ;;
    '~/'*) target="$HOME/${target#\~/}" ;;
esac
if [ -z "$target" ]; then
    echo "错误：--target 不能为空。" >&2
    exit 2
fi
# 规范化为绝对路径（目标可能还不存在，因此只规范化其父级）
target_parent="$(dirname -- "$target")"
target_base="$(basename -- "$target")"
mkdir -p -- "$target_parent"
target_parent="$(cd -- "$target_parent" && pwd)"
target="$target_parent/$target_base"

exclude_private_1="reference/00-source-requirements.md"
exclude_private_2="reference/12-projects-context.md"

# ---- 复制前确认 -------------------------------------------------------------
echo
echo "engineering-mentor 技能安装"
echo "  源目录 : $source_dir"
echo "  目标   : $target"
echo "  模式   : 仅复制，不删除目标目录中已有的任何文件"
echo

if [ "$force" -ne 1 ]; then
    if [ -t 0 ]; then
        printf '将从上面的“源目录”复制到“目标”，继续吗？[y/N] '
        read -r answer || answer=""
        case "$answer" in
            y|Y|yes|YES) ;;
            *)
                echo "已取消，未做任何修改。"
                exit 0
                ;;
        esac
    else
        echo "错误：当前不是交互式终端，无法确认。请加 --force 明确表示继续。" >&2
        exit 2
    fi
fi

if [ ! -d "$target" ]; then
    mkdir -p -- "$target"
    echo "已创建目标目录：$target"
fi

# ---- 执行复制 ---------------------------------------------------------------
if command -v rsync >/dev/null 2>&1; then
    rsync -a \
        --exclude "$exclude_private_1" \
        --exclude "$exclude_private_2" \
        --exclude '.git/' \
        --exclude 'install/' \
        "$source_dir/" "$target/"
    echo "已使用 rsync 完成复制（增量，不删除目标中已有的其他文件）。"
else
    echo "警告：系统里找不到 rsync，退化为 cp -R（不具备增量与精确排除能力）。" >&2
    cp -R "$source_dir/." "$target/"
    # 退化路径下必须自己清掉本应排除的内容（只删刚复制进来的这些私有/元数据路径）
    rm -rf -- "$target/$exclude_private_1" "$target/$exclude_private_2" "$target/.git" "$target/install"
    echo "警告：已用 cp -R 复制，并事后删除应排除的路径；建议安装 rsync 后重跑本脚本。" >&2
fi

# ---- 结果与提示 -------------------------------------------------------------
file_count="$(find "$target" -type f | wc -l | tr -d ' ')"

echo
echo "安装完成。"
echo "  目标路径 : $target"
echo "  目标文件 : $file_count 个文件"
echo "  已排除   : 两个私有 reference 文件、.git、install/"
echo
echo "请重启工具或新开一个会话：技能列表里应出现 engineering-mentor。"
echo "若未出现，请确认目标目录下直接存在 SKILL.md（即 <目标>/SKILL.md），且 frontmatter 里有 name 与 description。"
echo
