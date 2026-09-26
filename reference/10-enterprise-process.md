## 是什么与为什么

企业研发流程不是审批表，而是把"需求"逐步变成"可回滚的生产变更"的流水线。每个阶段的产出物（artifact）是下一阶段的输入，门禁（gate）由可验证的产物判定，不靠口头确认。依赖方向是单向的：**设计决定表结构 → 表结构决定接口 → 接口决定测试 → 测试决定能否合并 → 流水线决定能否发布**。倒过来做（先写代码再补设计、先上线再补文档）必然返工，因为下游已经按错误契约写好了。流程存在的另一个理由：生产上的错误往往不可撤销（用户数据、设备指令、资金），高风险动作必须先在同构的低风险环境用同样的流程走一遍；而能交接给下一个人的，只有仓库里的文件和可复现的命令。

完整生命周期（括号内是该阶段必须产出的东西）：

需求分析（一句话需求 + 用例 + 明确"本次不做什么"）→ 业务流程（流程图或状态机，含异常分支）→ 技术方案（备选方案对比 + 选型理由）→ 架构设计（模块边界 + ADR）→ 数据库设计（ER + 索引 + 迁移脚本）→ API 设计（OpenAPI 契约 + 错误码表）→ 编码（分层代码 + 完整类型标注，ruff/mypy 通过）→ 自测（成功与失败路径都手验）→ Code Review（变更 ≤400 行 + 至少 1 人批准）→ 单元/集成测试（关键分支有点名用例）→ CI/CD（任一环节失败即阻断）→ 测试环境（与生产同镜像同配置，冒烟通过）→ 生产发布（发布单 + 回滚命令）→ 监控（指标与告警规则齐备）→ 故障处理（先止血再定位，禁止只有重启）→ 复盘（无责记录，改进项带负责人与截止时间）。

判据必须可验证：每条索引要能说出服务哪个查询，契约冻结后前后端才能并行，回滚命令写不出来就等于没有发布资格。最容易跳过的三段依次是技术方案、API 契约和回滚方案——它们的代价都在发布阶段才结算。

细化见同目录 `04-data-api.md`（库表与接口）、`09-production-engineering.md`（可靠性）、`05-server-ops.md`（部署与流水线）、`11-security-crypto.md`（安全参数）。

## 最小可运行示例

写作时点组合：Python 3.11、FastAPI 0.x、pytest 8.x、pytest-asyncio、httpx、ruff、mypy、structlog、Alembic。安装前用 `pip index versions <包名>` 核对补丁版本。命令为 Ubuntu Bash（Windows PowerShell 下 git 子命令相同，虚拟环境激活换成 `.venv\Scripts\Activate.ps1`）。

### 一、可交付仓库的最小骨架

```text
project/
├─ app/
│  ├─ api/routers/device.py       # 只做参数校验与调用 service
│  ├─ services/device_service.py  # 业务规则
│  ├─ repositories/device_repo.py # 只做数据访问
│  ├─ models/ schemas/ adapters/ core/ middleware/ tasks/
│  └─ main.py                     # 只做装配：路由、中间件、异常处理
├─ tests/{unit,api,integration}/conftest.py
├─ migrations/                    # Alembic
├─ .env.example                   # 只写键名与示例值
├─ pyproject.toml                 # ruff / mypy / pytest / coverage 配置
├─ Dockerfile
└─ .github/workflows/ci.yml
```

### 二、Git 协作：一条命令序列走完一个功能

```bash
git switch main && git pull --ff-only
git switch -c feat/device-binding      # 命名：feat|fix|chore|docs/短横线描述
git add -A && git commit -m "feat(device): 支持扫码绑定设备"
git fetch origin && git rebase origin/main   # 个人分支用 rebase 跟主干，保持线性
git status                              # 冲突时：只列冲突文件
# 手工编辑，删净 <<<<<<< ======= >>>>>>> 三段标记，然后：
git add app/services/device_service.py && git rebase --continue   # 放弃重排：git rebase --abort
git push -u origin feat/device-binding  # 改写历史后只能用 git push --force-with-lease
# 平台上开 PR：动机/变更/影响面/测试证据/回滚方式；CI 绿 + 1 人批准后 squash merge
git switch main && git pull --ff-only
git tag -a v1.2.0 -m "设备绑定与共享上线" && git push origin v1.2.0
```

铁律：主干 `main` 永不直接 push、永不 force push；个人分支同步主干用 `rebase`；合入主干用 squash 或 `--no-ff` merge，保留 PR 边界。

### 三、pytest 最小示例

```python
# tests/conftest.py
import pytest
from httpx import ASGITransport, AsyncClient
from app.main import app

@pytest.fixture
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c

# tests/unit/test_device_service.py —— 只测逻辑，不碰数据库与网络
async def test_bind_rejects_offline_device(fake_repo):
    with pytest.raises(DeviceOfflineError):     # fake_repo 注入 service
        await bind_device(fake_repo, device_id=1, user_id=2)

# tests/api/test_device_api.py —— 只校验契约
async def test_bind_requires_auth(client):
    assert (await client.post("/api/v1/devices/1/bind")).status_code == 401
```

```bash
python -m pytest -q --cov=app --cov-report=term-missing   # 覆盖率门槛写在 pyproject.toml
```

### 四、CI 流水线骨架

```yaml
# .github/workflows/ci.yml
name: ci
on: [pull_request, push]
jobs:
  verify:
    runs-on: ubuntu-latest
    services:
      postgres: { image: postgres:16, env: { POSTGRES_PASSWORD: test }, ports: ["5432:5432"] }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.11" }
      - run: pip install -e ".[dev]"
      - run: ruff check . && ruff format --check . && mypy app
      - run: alembic upgrade head && pytest -q --cov=app --cov-fail-under=70
      - run: docker build -t app:${{ github.sha }} .
```

顺序固定为 **Lint → Test → Build → 镜像打 git sha 标签 → 部署测试环境 → 冒烟 → 人工审批 → 生产**。任一步失败即中断并通知，不允许"跳过测试先发布"。

## 工程实现要点

### 企业代码规范

- 命名：模块与函数 `snake_case`，类 `PascalCase`，常量 `UPPER_SNAKE`，布尔量用 `is_/has_/can_` 前缀，表名用复数 `snake_case`，API 路径用复数名词，测试文件 `test_<模块>.py`；禁止拼音命名与无意义缩写。
- 目录与分层：路由不写业务、业务不拼 SQL、仓储层不写业务规则；外部依赖（厂商 SDK、MQTT、支付、短信）一律走 `adapters/`；跨层依赖单向：`api → services → repositories → models`。
- 类型标注与注释：公共函数标注参数与返回值，禁止裸 `Any`（确需时在注释里写原因）；mypy 进 CI；注释解释"为什么"（约束、坑、出处链接），不解释"做了什么"，公共函数写 docstring 含参数、返回与抛出的异常。
- 日志：structlog 输出 JSON，形如 `logger.info("device_bind_ok", device_id=..., user_id=..., trace_id=...)`；事件名固定便于聚合；禁止 `print` 与 f-string 拼日志；严禁记录密码、Token、完整手机号、身份证。
- 异常：定义 `AppError` 基类（`code / message / http_status`），业务异常继承它，全局 handler 统一转 JSON；捕获范围尽量小，禁止 `except Exception: pass`。
- 配置：pydantic-settings 从环境变量读，启动时校验必填项（快速失败）；`.env.example` 入库，`.env.*` 进 `.gitignore`；代码里不出现真实密钥。
- 公共组件：统一响应体、分页、错误码表、ID/时间工具、依赖注入（`Depends`）；同一逻辑出现第三次再抽象，避免过早抽象。
- SOLID 与设计模式：单一职责与依赖倒置体现在分层和 Adapter 上；策略模式用于 `ControlService`（Mock/MQTT/SDK/ROS2 实现同一接口）；仓储模式隔离存储，工厂负责装配实现。模式为了可替换、可测试，不为显得高级。

### Git 团队协作的选型与规则

- 分支模型：主干开发（Trunk Based Development）只保留 `main` 加存活不超过 1–2 天的短分支，未完成功能用特性开关（Feature Flag）隐藏，适合发布频率高的团队；Git Flow（`main/develop/release/hotfix`）适合有固定发布窗口、需同时维护多个已发布版本的产品，代价是分支多、合并路径长。本项目默认走中间形态：`main` 始终可发布 + `feat/*`、`fix/*` 短分支 + tag。
- commit 与 PR：一次提交只做一件事且能跑通，禁止"一堆改动 + 消息写 update"；PR 变更 ≤400 行（超了拆），描述含动机、影响面、测试证据、回滚方式；Reviewer 重点看正确性、边界、安全、可维护性，格式问题交给 ruff/black 自动处理，不在评论里争风格。
- 版本与 Tag：语义化版本 `vMAJOR.MINOR.PATCH`；线上热修复从出问题的 tag 拉 `hotfix/*` 分支，修完打 patch 版本 tag，再回合主干。

### 测试体系

- 分层与 Mock 边界：单元测试只测纯逻辑不碰 IO；接口测试覆盖 HTTP 契约（成功、参数错、未认证、无权限）；集成测试连真实 PostgreSQL 与 Redis，验证 SQL、事务与迁移。只 Mock 外部不可控依赖（设备 SDK、MQTT、支付、短信），不要 Mock 自己的仓储层，否则测试全绿但 SQL 是错的。
- 测试数据库：每个用例事务回滚或使用独立 schema；迁移脚本必须在测试库完整跑一遍，否则迁移问题会留到生产才暴露。
- 覆盖率与回归测试：整体门槛 ≥70%，`services/` 与 `core/` ≥80%；覆盖率是下限不是目标，越权、超时、重复提交必须有专门用例；修 bug 的第一步是写一个能复现的失败测试，修复后它变绿并永久留在仓库。

### CI/CD 与环境隔离

- 四套环境：dev（本地）、test（每次合并自动部署）、staging（与生产同构，做发布前验证）、prod；配置全部来自环境变量，四处使用同一份镜像。流水线阶段固定：Lint → Test → Build → 推送镜像仓库（tag 等于 git sha，禁用 `latest`）→ 部署 test → 冒烟 → 人工审批 → 灰度或滚动发布 prod → 观察窗口 ≥30 分钟。
- 数据库升级与回滚：用 expand–contract 两阶段（先加新列并双写 → 切读 → 再删旧列），保证发布期间新旧代码都能跑；上线前先备份。镜像回滚（改回上一个 sha）通常分钟级，数据变更回滚需要单独脚本并标注预计耗时——发布单必须同时写清这两件事。

### 安全底线

- 密码只存哈希（bcrypt 或 Argon2id），加盐且不可逆；JWT 用短 Access Token（15–30 分钟）加可撤销 Refresh Token（7–30 天，服务端存哈希），校验 `alg/exp/iss/aud`，签名密钥至少 32 字节随机值。
- 权限：RBAC 之外，每次请求都要校验资源归属（防越权与 IDOR）；数据库账号、容器运行用户、云凭证一律按最小权限授予。
- 注入与前端：SQL 全部参数化（SQLAlchemy 绑定参数），禁止字符串拼接；XSS 靠输出转义加 CSP；纯 Authorization 头方案天然免 CSRF，若用 Cookie 则加 `SameSite=Lax` 与 CSRF token。
- 限流与跨域：登录 5 次/分钟/IP，写接口按用户维度限流，用 Nginx `limit_req` 或 Redis 令牌桶，429 响应带 `Retry-After`；全站 HTTPS 加 HSTS；CORS 白名单写确切 origin，禁止 `*` 与 `allow_credentials` 同时开启。
- 密钥、审计与依赖：密钥由环境变量或密钥管理服务下发，支持轮换，不进仓库、不进日志，用 gitleaks 类 pre-commit 钩子扫描历史提交；关键操作写审计日志（谁、何时、对哪个资源、做了什么、结果如何）；CI 跑 `pip-audit` 或依赖机器人，高危漏洞阻断合并。

### 文档清单（都是交付物）

README（5 分钟能跑起来）｜部署文档（环境变量、端口、依赖服务、启动与回滚命令）｜API 文档（OpenAPI 自动生成 + 变更说明）｜数据库说明（ER、索引用途、迁移历史）｜架构说明（模块边界与 ADR）｜测试报告（用例数、覆盖率、未覆盖项及原因）｜发布说明（新增/变更/修复/不兼容点/回滚点）｜故障复盘（时间线、根因、改进项）。

### 学习写法 vs 生产写法

1. **入口文件**
   ① 初学者为什么这样写：路由、SQL、业务全写在 `main.py`，改一处就能跑，不用理解分层。② 企业怎么写：`main.py` 只做装配，业务在 services、SQL 在 repositories、外部依赖在 adapters，用 `Depends` 注入。③ 差异原因：分层让"换 SDK、换数据库、加测试"只改一个文件，而单文件到 2000 行后改一处会牵连所有接口，且无法单独测试。
2. **错误处理与日志**
   ① 初学者为什么这样写：`print(e)` 加 `except Exception: pass`，界面不报错就算成功。② 企业怎么写：分类异常 + 全局 handler 返回规范 JSON（生产不带堆栈）+ 结构化日志带 trace_id。③ 差异原因：线上问题无法复现时，唯一线索是日志与指标；吞异常会把故障变成"数据悄悄不一致"，排查成本高一个数量级。
3. **验证方式**
   ① 初学者为什么这样写：手工点一遍界面，通过就交付。② 企业怎么写：pytest 覆盖成功、参数错、未认证、无权限、越权，CI 绿才允许合并，发布前在 staging 冒烟。③ 差异原因：手工验证不可重复、不可回归、覆盖不到并发与异常路径；CI 门禁把"我记得测过"变成"机器证明测过"。
4. **密钥与配置**
   ① 初学者为什么这样写：数据库密码、JWT 密钥直接写进代码，最省事。② 企业怎么写：只从环境变量或密钥管理服务读，`.env.example` 入库，真实值在提交前被 pre-commit 拦下。③ 差异原因：仓库一旦泄露（含历史提交）密钥即永久泄露，事后轮换的成本远高于一开始就分离配置。

## 功能交付检查单（Definition of Done）

用法：功能开工前扫一遍，明确这次要交什么；提 PR 前逐条勾选。★ 为必选项，缺一项不算交付。完整版见 `templates/dod.md`。

- [ ] ★ 需求一句话说清（谁、什么场景、解决什么问题），并写明本次不做什么
- [ ] ★ 业务流程含异常分支（离线、超时、权限不足、重复提交）
- [ ] ★ 关键取舍写进 ADR（备选方案、选择理由、放弃理由）
- [ ] ★ 接口契约完整：路径、方法、请求体、响应体、状态码、错误码；契约变更已通知调用方
- [ ] ★ 数据库变更走迁移脚本且可回滚；新增查询有索引并说明服务哪个查询
- [ ] ★ 分层正确：路由不写业务、业务不直连 SQL 细节、外部依赖走 Adapter
- [ ] ★ 类型标注完整，ruff 与 mypy 通过
- [ ] ★ 未捕获异常返回规范 JSON，生产响应不含堆栈；日志结构化并带 trace_id/request_id
- [ ] ★ 配置与密钥来自环境变量；仓库、日志、错误响应中无真实密钥与明文敏感字段
- [ ] ★ 外部调用设置超时（默认连接 3s、读取 5s）；需要重试处用指数退避且上限 3 次
- [ ] ★ 写操作幂等（request_id、唯一索引或 Redis 标记），重复提交不产生重复数据
- [ ] ★ 权限校验覆盖资源归属（防越权/IDOR），不只校验"已登录"
- [ ] ★ 单元测试覆盖核心逻辑与边界；接口测试覆盖成功/参数错/未认证/无权限
- [ ] ★ 覆盖率达标：整体 ≥70%，services 与 core ≥80%
- [ ] ★ 修 bug 附带"先失败、后通过"的回归测试
- [ ] ★ CI 全绿：Lint → Test → Build 任一环节失败即不合并
- [ ] ★ 健康检查覆盖依赖（数据库、Redis、MQTT 等）
- [ ] ★ 部署与配置变更写清（新环境变量、新服务、新端口），README 或接口文档同步更新
- [ ] ★ 回滚方案明确：镜像回滚 tag + 数据迁移回滚步骤 + 预计耗时
- [ ] ★ 先在 test/staging 验证再上生产；数据迁移在备份之后执行
- [ ] ★ 上线后观察 ≥30 分钟（错误率、P95 延迟、关键业务指标）
- [ ] ★ 关键操作有审计日志；依赖无已知高危漏洞
- [ ] 变更说明与影响范围已通知相关方；本次耗时与预估差异、踩到的坑与规避方式已记录

## 常见坑与验收标准

### 常见坑

- 把阶段当审批：只签字不看产物。判据是每个阶段的产出物都能在仓库里找到对应文件，找不到就是没做。
- 越过分层把 SQL 写进路由：换表或加索引时要改到所有调用点，且无法独立测试。
- 全量 Mock：集成测试全绿，但真库迁移失败、SQL 语法错；至少要保留一条连真实数据库的链路。
- 刷覆盖率数字：断言没有业务含义。改看越权、超时、重复提交这几条是否有点名用例。
- 迁移不可回滚、发布没有回滚点：直接 `DROP COLUMN` 上生产，或镜像用 `latest` 导致出事不知道退回哪个版本；默认用 expand–contract 分两次发布，镜像 tag 必须等于 git sha。
- 流程照搬：小团队硬上 Git Flow 加多层审批，结果是被绕过；流程强度要按发布风险定。
- 复盘变成追责：之后没人再报真实故障。复盘对事不对人，改进项必须带负责人与截止时间。

### 验收标准（证明"我真的会了"）

1. 给一个功能，你能在不动代码的前提下写出：一句话需求、异常分支清单、接口契约、表与索引、回滚方案。
2. 你能在 10 分钟内从零跑通仓库：clone → 配 `.env` → 起依赖 → 跑测试 → 起服务，全程只看 README。
3. 你的 PR 交给没参与开发的同事 review 时，他能只凭描述与测试判断影响面，不需要来问你。
4. 你能对一个历史 bug 演示"先写失败测试、再修复、测试转绿"的完整过程，并读懂 CI 失败日志判断它属于 lint、类型检查、测试还是构建。
5. 你能在 staging 演练一次发布与回滚，并给出两者各自的实际耗时。
6. 你能产出一份含 3 条改进项的复盘记录，且其中至少一条已固化进检查单。

## 学习路径

前置：`02-se-foundations.md`（Git、Linux、HTTP 基本功）与 `03-app-web-backend.md`（分层骨架）。没有这两块，流程只能背名词。

每一步都要有可交付物：

1. 单人走通闭环：用短分支 + PR 模式提交一个真实小功能，产出一次自审 PR 与一个 tag。
2. 加自动化：接入 ruff、mypy、pytest 与 CI，产出一条失败的红色流水线以及修复它的提交。
3. 加分环境与迁移：搭起 dev/test 两套环境，写 Alembic 迁移并自动部署到 test，产出一次可回滚的迁移记录。
4. 加 Code Review：请一人（或让 AI 扮演 reviewer）提出至少 3 条有效意见，产出 review 记录与修改后的 diff。
5. 加发布纪律：走完 staging → 灰度 → 观察 → 回滚演练，产出发布单与复盘各一份。
6. 加安全与文档：按检查单补齐权限、限流、密钥管理、审计日志与八类文档，产出一份能直接交给新同事的交付包。

里程碑判定：不需要逐步指导就能独立完成第 5 步的发布与回滚，说明已具备企业级交付的基本能力；第 6 步是长期维护标准。
