# awesome-design-md (Agent Skill)

> 54 份来自真实产品的 `DESIGN.md` 设计系统文档，封装为可被 AI 编码 Agent 直接加载的 **Skill**。
> 说一句「做成 Stripe 风格」，Agent 就会读取对应设计规范并生成品牌级 UI。

设计文档内容源自 [VoltAgent/awesome-design-md](https://github.com/VoltAgent/awesome-design-md)（MIT），本仓库在其基础上封装为 Skill 形态，补齐了触发条件、路由表与工作流。

---

## 什么是 DESIGN.md

`DESIGN.md` 是 [Google Stitch](https://stitch.withgoogle.com/docs/design-md/overview/) 提出的概念：一份纯文本的设计系统文档。把它放进项目根目录，任何 AI 编码 Agent 都能立刻理解这个项目的 UI 应该长什么样——配色、字体、间距、组件状态、阴影层级，全部可读。

每份文档包含 9 个章节：

| # | 章节 | 内容 |
|---|------|------|
| 1 | Visual Theme & Atmosphere | 氛围、信息密度、设计哲学 |
| 2 | Color Palette & Roles | 语义色名 + HEX + 功能角色 |
| 3 | Typography Rules | 字体族、完整层级表 |
| 4 | Component Stylings | 按钮/卡片/输入框/导航及各状态 |
| 5 | Layout Principles | 间距刻度、栅格、留白哲学 |
| 6 | Depth & Elevation | 阴影系统、surface 层级 |
| 7 | Do's and Don'ts | 设计护栏与反模式 |
| 8 | Responsive Behavior | 断点、触控目标、折叠策略 |
| 9 | Agent Prompt Guide | 速查色板、可直接使用的提示词 |

---

## 安装

本仓库是技能集合仓库，该技能位于 `skills/awesome-design-md/`。

### WorkBuddy

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/lly1216/Skill.git _tmp-skill
cd _tmp-skill && git sparse-checkout set skills/awesome-design-md
cp -r skills/awesome-design-md ~/.workbuddy/skills/awesome-design-md
```

### Claude Code / 其他支持 Skill 的 Agent

```bash
# 同上取出子目录后：
cp -r skills/awesome-design-md ~/.claude/skills/awesome-design-md
```

### 只要 DESIGN.md（不用 Skill）

`references/` 下 54 个文件可直接复制使用：

```bash
cp references/stripe.md /path/to/your/project/DESIGN.md
```

---

## 使用方式

Skill 有三种触发路径，Agent 会自动判断：

**1. 指定品牌 → 直接匹配**

```
"帮我做一个像 Stripe 风格的落地页"
→ 读取 references/stripe.md → 用其 token 生成 UI
```

**2. 想挑一挑 → 按条件筛选推荐**

```
"有没有暗色系的设计系统？"
→ 推荐 Vercel / Cursor / ElevenLabs / Resend / Warp / Supabase 等
```

**3. 没指定风格 → 按项目类型主动推荐**

```
"帮我做一个 AI 聊天产品的界面"
→ 推荐 Claude、Mistral AI、ElevenLabs、Vercel、VoltAgent
→ 选一个即可生成
```

若用户说「随便 / 你决定」，默认使用 **Vercel**（最安全的中性风格：简约黑白、现代、专业）。

---

## 收录的设计系统（54 个）

### AI & 机器学习（12）
Claude · Cohere · ElevenLabs · Minimax · Mistral AI · Ollama · OpenCode AI · Replicate · RunwayML · Together AI · VoltAgent · xAI

### 开发者工具与平台（14）
Cursor · Expo · Linear · Lovable · Mintlify · PostHog · Raycast · Resend · Sentry · Supabase · Superhuman · Vercel · Warp · Zapier

### 基础设施与云（6）
ClickHouse · Composio · HashiCorp · MongoDB · Sanity · Stripe

### 设计与生产力（10）
Airtable · Cal.com · Clay · Figma · Framer · Intercom · Miro · Notion · Pinterest · Webflow

### 金融科技与加密（4）
Coinbase · Kraken · Revolut · Wise

### 企业级与消费品牌（8）
Airbnb · Apple · BMW · IBM · NVIDIA · SpaceX · Spotify · Uber

---

## 目录结构

```
awesome-design-md-skill/
├── SKILL.md              # Skill 定义：触发条件、路由表、工作流
├── README.md             # 本文件
├── LICENSE               # MIT
└── references/           # 54 份 DESIGN.md
    ├── stripe.md
    ├── vercel.md
    ├── linear.app.md
    └── ...
```

---

## 项目类型 → 推荐风格速查

| 项目类型 | 推荐 | 理由 |
|---|---|---|
| SaaS 官网 / 落地页 | Stripe、Vercel、Linear | 经典高转化 SaaS 风格 |
| 开发者工具 | Vercel、Cursor、Raycast、Supabase | 暗色、代码友好 |
| AI 产品 / Chat UI | Claude、Mistral AI、ElevenLabs | AI 原生设计语言 |
| Fintech | Stripe、Revolut、Coinbase | 信任感、精密感 |
| 效率工具 | Notion、Linear、Superhuman | 极简、高密度、键盘优先 |
| 电商 / 消费品牌 | Airbnb、Apple、Spotify | 视觉驱动、情感化 |
| 后台 / Dashboard | Sentry、PostHog、ClickHouse | 数据密集型暗色仪表盘 |
| 创意 / 设计工具 | Figma、Framer、Clay | 大胆配色、动感 |
| 企业级 B2B | IBM、HashiCorp、MongoDB | 稳重、结构化 |

---

## 声明

所有 DESIGN.md 均提取自各网站公开可见的 CSS 值，仅用于帮助 AI Agent 生成一致的 UI。本仓库不主张任何站点的视觉识别所有权。

## License

MIT — 详见 [LICENSE](./LICENSE)。原始内容版权归 [VoltAgent/awesome-design-md](https://github.com/VoltAgent/awesome-design-md) 所有。
