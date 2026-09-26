# 更新日志（Changelog）

本文件记录 engineering-mentor 技能的版本变更。
格式参考 [Keep a Changelog](https://keepachangelog.com/)，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

> 说明：未发布的版本不写日期，发布时再补 `YYYY-MM-DD`。技能本身没有构建产物，
> "版本"指 `SKILL.md` 与其 `reference/`、`templates/`、`install/` 的内容快照。

## [Unreleased]

暂无。

## [0.3.0] - 2026-09-26

补齐相对原始需求遗漏的三块内容。

### 新增

- `reference/13-frontend-web.md`：前端与网站专题（HTML/CSS 与布局、TypeScript 工程、Vue 3 为主实现与 React 关键差异对照、前端工程化与 Nginx 部署、与后端契约、组件测试与性能、移动端形态选型）。
- `reference/09-production-engineering.md`：新增"任务队列与 Celery（异步作业工程化）"一节。
- `reference/10-enterprise-process.md`：新增"微服务基础（何时该拆，何时不该）"一节。

### 变更

- `SKILL.md` 的 frontmatter `description` 加入前端、微服务与异步任务队列触发词，使前端类问题能被自动匹配。
- `SKILL.md`、`AGENTS.md`、`README.md` 的文档索引与能力范围同步更新。

### 说明

- 移动端形态（H5 / 小程序 / uni-app / React Native）在文档中标为 `待核实`：学习者项目的实际形态未知，不做假设。

## [0.2.0] - 2026-09-26

本次改造的目标：从"只在单一宿主里能用的本地技能"变成**可跨工具安装、可公开发布的开源包**，
同时保证个人信息不进仓库。

### Added

- `AGENTS.md`：新增通用适配入口，供读取 AGENTS.md 格式的工具（Codex、Cursor、Gemini CLI、Copilot、
  Windsurf、Zed、Amp、Aider、goose、opencode、Jules、Factory 等）直接使用；完整协议仍指向 `SKILL.md`。
  来源与格式说明：<https://agents.md/>。
- `install/install.ps1`：Windows PowerShell 5.1+ / PowerShell 7 安装脚本，参数 `-Target`、`-Source`、`-Force`，
  复制前要求确认（`-Force` 跳过），只增不删，复制时排除两个私有文件、`.git` 与 `install/`。
- `install/install.sh`：Linux/macOS Bash 安装脚本（`set -euo pipefail`），参数 `--target`、`--source`、`--force`，
  优先用 `rsync -a --exclude`，无 `rsync` 时退化为 `cp -R` 并在复制后清理应排除路径（排除项同上）。
- `install/make-skill-zip.ps1`：打包 `engineering-mentor-<版本>.zip`，排除私有文件、`.git`、`install/`、
  `README.md`、`LICENSE`、`CHANGELOG.md`、`.gitignore`、`AGENTS.md`，供只能上传 ZIP 的工具使用。
- `README.md`：中英双语说明，含按工具分节的安装命令、目录结构、三种触发方式、学习档案与自定义指引。
- `LICENSE`：MIT 全文（版权行含占位符，发布前需替换）。
- `CHANGELOG.md`：本文件。
- `.gitignore`：**隐私防线**。排除 `reference/00-source-requirements.md`、
  `reference/12-projects-context.md`、`learning/`、打包产物与常见系统/编辑器垃圾文件。
- `templates/projects-context.md`：通用项目上下文模板，替代原来只能本地保存的项目上下文文件；
  用户复制到自己的档案目录填写，模板本身可安全入库。

### Changed

- **宿主无关化**：`SKILL.md` 去掉单一宿主专属的工具名、硬编码绝对路径与本机约定，
  改为任何支持 Agent Skills 标准（`SKILL.md` + YAML frontmatter）或 AGENTS.md 的工具都能执行。
- **学习档案路径**改为按顺序解析：`$ENGINEERING_MENTOR_HOME` → 当前项目内 `learning/` →
  用户主目录 `~/.engineering-mentor/`；不再固定到某个盘符路径。
- 技能目录定位为**只读资源**，所有产出（档案、练习代码、笔记、排查记录）写进工作区或档案目录。
- 版本号由 0.1.0 提升到 0.2.0。

### Security

- 两个私有 reference 文件（原始诉求原文、项目上下文）**改为不入库**：仅保留在本地，
  由 `.gitignore` 与安装/打包脚本双重排除；文件本身**未删除、未修改**，本地照常可用。
- 公开仓库不含任何个人信息：无用户名、无本机盘符路径、无个人项目名、无学习起点评估。

### 待核实

- claude.ai、Kimi 等"上传 ZIP"工具的菜单路径、技能入口名称与包大小限制：官方文档未查证，
  README 中相应处以 `待核实` 标注并给出核实途径。
- Cursor 是否必须使用 `.cursor/rules/*.mdc` 而非 `AGENTS.md`：agents.md 已将 Cursor 列为支持方，
  按该表述书写；若需以官方文档确认，请核实 Cursor 官方规则文档。

## [0.1.0] - 首次构建

首个可用版本：确立"教学与陪练协议"的整体结构，并在单一宿主内实测可用。

### Added

- `SKILL.md`：工作协议主体。三条不可违背的原则（真实性优先、抗依赖、安全前置）；
  三档工作模式（讲解 / 陪练 / 审查）与切换规则；讲解顺序规范；报错排查七步法；
  掌握判定三件套与账本状态机；企业交付标准；机器人六级安全门禁；输出风格；资源索引；复习与出师标准。
- `reference/` 专题文档：计算机与工程基础、APP/网站后端、数据库与 API、服务器与运维、
  ROS 2 与感知导航、下位机与 SDK/总线通信、四足运控与安全门禁、生产级工程、
  企业研发流程、安全与密码学，以及仅供本地使用的原始诉求与项目上下文两份私有文档。
- `templates/`：`progress.md`（进度账本）、`lesson-plan.md`（学习计划）、
  `error-triage.md`（排查记录）、`adr.md`（架构决策记录）、`dod.md`（交付检查单）。

> 版本对比链接：仓库地址确定后再补，当前不填，避免出现失效链接。
