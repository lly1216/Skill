# engineering-mentor

## 1. 一句话说明

**把"教你怎么学、陪你怎么做"写成一份可安装的工程指导技能：用你自己的项目当训练载体，
按「原理 → 最小示例 → 工程实现 → 调试 → 生产化」推进，并把学习进度沉淀成本地档案。**

**仓库地址**：<https://github.com/lly1216/skill>

```bash
git clone https://github.com/lly1216/skill.git
```

<!-- 徽章留白：需要时可在此处添加徽章（CI 状态、License、版本等）。
     本仓库目前没有 CI 与发布流水线，为避免失效链接，此处不预置任何徽章。 -->

| 项目 | 说明 |
| --- | --- |
| 许可 | [MIT](LICENSE)，版权归 lly1216 |
| 版本 | 0.2.0，见 [CHANGELOG.md](CHANGELOG.md) |
| 格式 | Agent Skills 开放标准：`SKILL.md` + YAML frontmatter（`name`、`description`） |
| 语言 | 技能正文为简体中文 |

## 2. 这是什么

这是一份**工作协议**，不是人格设定：安装后它按固定流程工作，不扮演角色、不写开场白。

它是**教学与陪练协议**，不是代码生成器。默认行为是把关键路径代码留给学习者自己写，
只给接口、骨架、验收标准与评审意见；只有当用户明确要"能直接跑的成品"时才直接给实现。
每一轮都要求声明模式（讲解 / 陪练 / 审查）、给出可见产出，并在结束时更新学习档案。

它约束的是**方法**：真实性优先（没看到真实文件不得编造接口名、参数、Topic 名）、
抗依赖（逐渐让学习者独立）、安全前置（运动控制与生产写操作先仿真或先只读验证）。

## 3. 能力范围

三条主线，外加贯穿三线的生产级可靠性要求。

### 3.1 后端与数据

- 业务域建模与分层（路由 / 服务 / 仓储 / 模型），FastAPI 工程化组织、依赖注入、配置与密钥分离。
- 认证授权与权限模型（JWT、会话、角色与资源级鉴权）、API 规范、分页、错误码、版本演进。
- PostgreSQL 设计与索引、事务与隔离级别、迁移（Alembic）、Redis 缓存与失效策略。
- 实时链路：WebSocket / MQTT 的消息语义、断线重连、去重与幂等。

### 3.2 服务器与运维

- Linux 基础与排障：进程、端口、文件句柄、磁盘、网络，按现象逐层定位而不是乱试命令。
- Nginx 反向代理与 HTTPS、静态资源与限流；Docker / Compose、镜像分层与环境一致性。
- CI/CD 流水线（lint → test → build → 部署 → 冒烟 → 回滚），四套环境的配置注入方式。
- 监控告警、日志与追踪、备份与恢复演练、容量与成本控制。

### 3.3 机器人与嵌入式

- ROS 2：节点 / 话题 / 服务 / 动作、TF 与坐标系、QoS 与实时性、常见通信故障排查。
- 传感器接入与标定、SLAM 建图与定位、Nav2 导航与避障调试。
- 下位机 / MCU 与 SDK 二次开发、总线通信（CAN / RS485 / EtherCAT）、分层网络排查。
- 四足运控算法与分级安全门禁：`G0 仿真 → G1 低速低力矩 → G2 单腿悬空 → G3 站立平衡 →
  G4 整机低速 → G5 常规运行`，未过闸不得进入下一级。

### 3.4 贯穿三线

生产级可靠性（幂等、超时、降级、可观测、压测）与安全（加密存储、密钥管理、审计、依赖漏洞）
以及企业交付标准（`templates/dod.md` 的 Definition of Done 检查单）。

## 4. 安装

按你使用的工具选一种安装方式（4.1–4.5 共五种，未查证事项见 4.6）。所有脚本都**只复制、不删除**目标目录里已有的文件。

### 4.1 DeepSeek Harness

技能扫描根为 `$DSH_HOME/skills/<name>/SKILL.md`（`DSH_HOME` 未设置时默认 `~/.dsh`）。

```powershell
# Windows PowerShell：安装到 DSH 全局技能目录
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME ".dsh" }
pwsh -File .\install\install.ps1 -Target (Join-Path $dshHome "skills\engineering-mentor")
```

```bash
# Linux / macOS Bash
bash install/install.sh --target "${DSH_HOME:-$HOME/.dsh}/skills/engineering-mentor"
```

### 4.2 通用 AGENTS.md（Codex、Cursor、Copilot、Windsurf 等）

AGENTS.md 是开放格式，无必填字段，就是普通 Markdown，**就近的文件优先**，已被 6 万多个项目采用。
支持它的工具包括 Codex、Jules、Factory、Aider、goose、opencode、Zed、Warp、VS Code、Devin、
Junie、Amp、Cursor、RooCode、Kilo Code、Phoenix、Semgrep、GitHub Copilot、Ona、Windsurf、
Augment Code 等。来源：<https://agents.md/>。

```powershell
# Windows PowerShell：把通用入口放到项目根目录
Copy-Item ".\engineering-mentor\AGENTS.md" ".\AGENTS.md"
```

```bash
# Linux / macOS Bash
cp ./engineering-mentor/AGENTS.md ./AGENTS.md
```

### 4.3 Claude Code 及其他支持 Agent Skills 的工具

Claude Code 遵循 Agent Skills 开放标准，技能放在个人目录 `~/.claude/skills/<skill-name>/SKILL.md`
或项目目录 `.claude/skills/<skill-name>/SKILL.md`，技能目录里可以放支持文件
（本技能的 `reference/` 与 `templates/`）。来源：<https://agentskills.io>、
<https://code.claude.com/docs/en/skills>。

```bash
# Linux / macOS Bash：个人技能目录（脚本的默认目标就是这里）
bash install/install.sh

# 或安装到当前项目内
bash install/install.sh --target "$PWD/.claude/skills/engineering-mentor"
```

```powershell
# Windows PowerShell：默认目标 $HOME\.claude\skills\engineering-mentor
pwsh -File .\install\install.ps1

# 安装到当前项目内
pwsh -File .\install\install.ps1 -Target ".\.claude\skills\engineering-mentor"
```

### 4.4 只能上传 ZIP 的工具（claude.ai、Kimi 等）

这类工具只需要技能本体，所以打包脚本会排除 `install/`、`README.md`、`LICENSE`、`CHANGELOG.md`、
`.gitignore`、`AGENTS.md`、`.git` 与两个私有文件：

```powershell
# Windows PowerShell：输出 dist/engineering-mentor-0.2.0.zip
pwsh -File .\install\make-skill-zip.ps1 -Version 0.2.0 -OutDir .\dist
```

ZIP 内的结构是根下 `engineering-mentor/`，其第一层直接是 `SKILL.md`。仓库目前只提供
PowerShell 打包脚本；其他平台请自行用系统 `zip` 工具按上面同一份排除清单打包。

**待核实**：上传入口的菜单路径、技能/知识库栏目名称与体积上限。核实途径：对应工具的官方帮助中心
或设置页里的"技能 / 知识库 / 上传文件"文档，以及上传界面自身的提示。脚本运行结束时会打印 zip 路径与
前 20 项内容清单，上传前请核对清单里**没有** `reference/00-source-requirements.md` 与
`reference/12-projects-context.md`。

### 4.5 Gemini CLI

Gemini CLI 需要把 `context.fileName` 设为 `AGENTS.md`（同时按 4.2 节把 `AGENTS.md` 放到项目根目录）。
在项目根的 `.gemini/settings.json` 写入：

```json
{
  "context": {
    "fileName": "AGENTS.md"
  }
}
```

来源：<https://agents.md/>。

### 4.6 其他未查证事项

- **待核实**：Cursor 是否必须改用 `.cursor/rules/*.mdc` 而不是 `AGENTS.md`。当前按
  <https://agents.md/> 把 Cursor 列为 `AGENTS.md` 支持方来表述；核实途径：Cursor 官方规则文档。
- **待核实**：其他未在 <https://agents.md/> 与 <https://agentskills.io> 列出的工具，
  其技能目录位置与安装方式。核实途径：该工具官方文档中的"skills / rules / 配置目录"章节。

## 5. 目录结构

技能根 = 仓库根（`SKILL.md` 就在根目录）。

| 路径 | 作用 |
| --- | --- |
| `SKILL.md` | 主协议与 Agent Skills 入口：frontmatter 的 `name`、`description` 决定何时被自动匹配 |
| `AGENTS.md` | 规则类工具（Codex、Cursor、Gemini CLI 等）的通用适配入口，正文为协议要点摘要 |
| `reference/` | 专题文档，按需读取：`01` 教学细则、`02` 计算机与工程基础、`03` 后端、`04` 数据与 API、`05` 服务器运维、`06` ROS 2、`07` 嵌入式与总线、`08` 运控与安全、`09` 生产级工程、`10` 研发流程、`11` 安全与密码学 |
| `templates/` | `progress.md` 进度账本、`lesson-plan.md` 学习计划、`error-triage.md` 排查记录、`adr.md` 架构决策、`dod.md` 交付检查单、`projects-context.md` 项目上下文模板 |
| `install/` | 安装与打包脚本：`install.ps1`、`install.sh`、`make-skill-zip.ps1` |
| `README.md`、`LICENSE`、`CHANGELOG.md`、`.gitignore` | 仓库级文件；`.gitignore` 是隐私防线，见第 7 节 |

`reference/00-source-requirements.md` 与 `reference/12-projects-context.md` 是**仅供本地使用**的私有文件，
已被 `.gitignore` 排除，不会出现在公开仓库里，本地存在与否不影响技能运行。

## 6. 怎么用

三种触发方式：

1. **自动匹配**：把技能放到工具的技能目录后，描述与任务相关时会自动加载（`description` 已覆盖学习、
   讲原理、带做项目、代码审查，以及后端、运维、机器人三类技术主题）。
2. **显式点名**：在支持手动调用的工具里直接输入技能名 `engineering-mentor`（具体召唤语法以宿主文档为准）。
3. **贴进系统提示**：对不支持技能机制的工具，把 `SKILL.md` 全文（或 `AGENTS.md`）粘进对话或系统提示。

最小使用示例：

```text
用户：我想给设备加一个"下发指令并等待执行结果"的接口，但我不太懂异步和超时该怎么设计。

导师（讲解模式）：
结论：先用"请求-确认-回调"三步模型，不要在设计阶段引入消息队列。
原理与数据流：客户端 → 后端接口 → 设备通道 → 设备 → 回执 → 后端 → 客户端。
最小示例：<一段最小可运行代码，含超时与状态字段>
工程实现：改 app/services/device_service.py 的状态机，新增 pending/acked/failed 三态。
调试：先只给 2 条命令，每条说明该看到什么。
生产化：幂等键、超时重试上限、失败告警、审计日志。
下一步：请你自己补状态机实现，写完我来 review（切审查模式）。
```

## 7. 学习档案与隐私

首次使用时技能会在本地创建学习档案（进度账本 `progress.md`、路线图 `roadmap.md`、`exercises/`、
`notes/`、`triage/`）。**档案位置按以下顺序解析**，确定后写进账本顶部并沿用：

1. 环境变量 `ENGINEERING_MENTOR_HOME` 指向的目录（若已设置）；
2. 当前项目根目录下的 `learning/`；
3. 用户主目录下的 `.engineering-mentor/`。

隐私约定：

- 档案可能包含你的项目细节与个人信息，**不要提交到公开仓库**；本仓库 `.gitignore` 已排除 `learning/`。
- `reference/00-source-requirements.md`、`reference/12-projects-context.md` 与 `*.zip` 同样被排除，
  安装与打包脚本也会主动跳过前两者。
- 技能目录视为**只读资源**：所有产出写进工作区或档案目录，不要往技能目录里写文件。
- 提 PR 时请先确认 diff 里没有你的档案、密钥、内网地址与个人项目信息。

## 8. 自定义

- **改专题内容**：`reference/*.md` 与 `templates/*.md` 都是普通 Markdown，直接改即可；
  改完重新安装（覆盖同名文件需加 `-Force` / `--force`）。
- **加自己的项目上下文**：复制 `templates/projects-context.md` 到你的档案目录，命名如 `projects.md`，
  按项目卡填写；它不会被提交到仓库。若你希望它随本地技能一起被读取，也可以把它保存成技能目录里的
  `reference/12-projects-context.md`——该路径已被 `.gitignore` 排除。
- **加自己的专题**：在 `reference/` 下按 `NN-主题.md` 命名新增文件，并在 `SKILL.md` 第 9 节的资源索引里
  补一行，保证技能知道何时去读它。
- **调整触发条件**：改 `SKILL.md` frontmatter 的 `description`，把你的任务域关键词写进去；
  `AGENTS.md` 开头也应同步补一句。

## 9. 贡献与许可

- 许可：[MIT](LICENSE)。
- 欢迎提 Issue 与 PR：修正技术性错误、补充 `reference/` 专题、改进 `templates/`。
- 提交前自查：不包含个人信息与密钥；安装命令在 <https://agentskills.io>、
  <https://code.claude.com/docs/en/skills>、<https://agents.md/> 里能找到依据；
  查不到的写 `待核实` 并给出核实途径，不要写成确定事实。
- 版本变更记录在 [CHANGELOG.md](CHANGELOG.md)（Keep a Changelog 风格，版本号遵循语义化版本）。

## 10. English summary

`engineering-mentor` is an installable **teaching-and-coaching skill** for full-stack
software/hardware engineering. It treats your own project as the training ground and moves
through *principle → minimal example → engineering implementation → debugging → production*.
It is a work protocol, not a code generator: on critical paths it hands you interfaces,
skeletons and acceptance criteria, then reviews your implementation.

It follows the Agent Skills open standard (`SKILL.md` + YAML frontmatter), so it installs into
Claude Code (`~/.claude/skills/engineering-mentor/`) and other compatible tools; an `AGENTS.md`
entry point covers rule-file tools such as Codex, Cursor and Copilot, and a ZIP packaging script
covers upload-only tools. Coverage spans three lines: backend/data (FastAPI, PostgreSQL, Redis,
WebSocket/MQTT), server and operations (Linux, Nginx, Docker, CI/CD, monitoring), and
robotics/embedded (ROS 2, SLAM/Nav2, MCU/SDK, CAN/RS485/EtherCAT, quadruped locomotion with a
staged safety gate). Progress is kept in a **local** learning archive
(`$ENGINEERING_MENTOR_HOME` → `./learning/` → `~/.engineering-mentor/`) that is never committed.

Licensed under MIT. See `README.md` §4 for per-tool install commands and `CHANGELOG.md` for version history.
