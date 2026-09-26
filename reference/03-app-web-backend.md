## 是什么与为什么

C 端 APP 后端（backend）是**业务状态的唯一权威副本**：APP 只展示与交互，设备只执行；账号、绑定、订单、权限、离线判定、指令流水全部由后端记账。链路：

`APP / 网站 → Nginx → FastAPI（router → service → repository）→ PostgreSQL / Redis → MQTT / ROS 2 / SDK Adapter → 设备`

每个业务域一套 `router + service + repository`，域之间只走 service 接口，不互相读表：

| 业务域 | 核心实体 | 关键约束 |
|---|---|---|
| 账号体系 | user、credential、refresh_session | 密码只存哈希；Access Token 短、Refresh Token 可吊销 |
| 设备绑定与列表 | device、device_binding | `(user_id, device_id)` 唯一；一台设备可被多人共享 |
| 状态与遥测 | device_state、telemetry | 高频写入走 Redis 或时序表，不污染业务表 |
| 远程控制 | command、command_ack | 必带 `request_id`、`timestamp`；离线绝不得返回成功 |
| 消息通知、社区、售后、个人中心、设备共享 | notification、post、comment、ticket、family | 站内信先落库；内容审核 + 软删除；工单状态机；成员变更失效权限缓存 |
| 商城 / 订单 / 支付（预留） | product、cart、order、payment | 支付只留适配器接口，回调必须验签 + 幂等 |

**业务与控制必须解耦**：社区、商城、订单、用户模块**禁止** import 任何设备 SDK。控制能力统一收口到抽象 `ControlService → MockControlService / MQTTControlService / SDKControlService / ROS2ControlService`：上层只依赖接口，没有真机时用 Mock，接入真机只新增或替换 Adapter，上层业务不动。

统一命令字段 `device_id、command、parameters、request_id、timestamp`；结果必须区分 `OK / OFFLINE / TIMEOUT / COMMAND_FAILED`——四种结果在 APP 的文案与重试策略完全不同，混成"成功 / 失败"两种就无法排查。

## 最小可运行示例

依赖：Python 3.11+、FastAPI、Uvicorn、SQLAlchemy 2.x（async）、Pydantic 2.x、pydantic-settings、PyJWT、passlib[bcrypt]、redis、structlog、alembic。小版本以官方文档当前稳定版为准，锁定版本交给锁文件。

```text
app/
  main.py                 # 只做装配：生命周期、中间件、路由挂载、异常注册
  api/deps.py             # DB Session、当前用户、RBAC、分页
  api/routers/            # auth.py device.py control.py community.py order.py
  services/               # auth_service.py device_service.py control_service.py（抽象接口）
  repositories/           # base.py user_repo.py device_repo.py command_repo.py
  models/                 # base.py user.py device.py order.py
  schemas/                # common.py auth.py device.py control.py
  adapters/               # mock_control.py mqtt_control.py sdk_control.py
  core/                   # config.py security.py errors.py logging.py
  middleware/  tasks/     # trace.py access_log.py ｜ celery_app.py push.py
  websocket/   mqtt/      # manager.py routes.py ｜ client.py handlers.py
tests/  alembic/  .env.example  docker-compose.yml
```

```python
# ---- app/main.py：只做装配，不写业务逻辑 ----
from contextlib import asynccontextmanager
from fastapi import FastAPI
from app.api.routers import auth, control, device
from app.core.config import settings
from app.core.errors import register_exception_handlers
from app.mqtt.client import mqtt_client
from app.middleware.trace import TraceMiddleware
from app.websocket.routes import router as ws_router

@asynccontextmanager
async def lifespan(app: FastAPI):   # 启动连 MQTT/Redis；关闭时先停收消息，再关连接池
    await mqtt_client.start(); yield; await mqtt_client.stop()

app = FastAPI(title="dog-app", version="v1", lifespan=lifespan, docs_url=None)  # 生产不暴露 Swagger
app.add_middleware(TraceMiddleware); register_exception_handlers(app)
for r, p in ((auth, "auth"), (device, "devices"), (control, "control")):
    app.include_router(r.router, prefix=f"/api/v1/{p}", tags=[p])
app.include_router(ws_router)       # WebSocket 推送路由

# ---- app/core/config.py ----
from pydantic_settings import BaseSettings, SettingsConfigDict
class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env.dev", extra="ignore")   # prod 换 .env.prod
    database_url: str           # postgresql+asyncpg://user:pwd@host:5432/db，只从环境变量读
    redis_url: str
    mqtt_host: str
    mqtt_port: int = 1883       # MQTT 明文标准端口；TLS 用 8883
    jwt_secret: str             # 无默认值：缺失即启动失败，禁止硬编码
    access_ttl_sec: int = 900        # 15 min：限制 Token 泄露窗口
    refresh_ttl_sec: int = 604800    # 7 day：再长则吊销成本过高
    db_pool_size: int = 10           # workers × (pool + overflow) < PG max_connections
    control_backend: str = "mock"    # mock | mqtt | sdk | ros2
settings = Settings()

# ---- app/core/security.py + app/api/deps.py（节选） ----
from datetime import datetime, timedelta, timezone
import jwt
from passlib.context import CryptContext

pwd = CryptContext(schemes=["bcrypt"], deprecated="auto")
hash_password, verify_password = pwd.hash, pwd.verify     # 哈希与校验只在服务端发生
def issue_tokens(user_id: str, jti: str) -> dict:
    now = datetime.now(timezone.utc)
    def enc(ttl: int, typ: str) -> str:
        claims = {"sub": user_id, "typ": typ, "jti": jti, "iat": now, "exp": now + timedelta(seconds=ttl)}
        return jwt.encode(claims, settings.jwt_secret, algorithm="HS256")   # 共验签场景改 RS256
    return {"access_token": enc(settings.access_ttl_sec, "access"),
            "refresh_token": enc(settings.refresh_ttl_sec, "refresh"),
            "token_type": "bearer", "expires_in": settings.access_ttl_sec}

async def get_db():                       # 一请求一 Session，不跨请求共享
    async with SessionLocal() as session: yield session

async def get_current_user(token: str = Depends(oauth2_scheme), db=Depends(get_db)) -> User:
    payload = decode_jwt(token)              # 验签 + 验 exp
    if payload["typ"] != "access": raise BizError("Token 类型错误", 40100, 401)
    if await redis.exists(f"revoked:{payload['jti']}"): raise BizError("Token 已吊销", 40100, 401)
    return await user_repo.get_or_404(db, payload["sub"])

def require(*roles: str):                    # RBAC 依赖工厂，挂在 router 上即生效
    async def _check(user: User = Depends(get_current_user)) -> User:
        if user.role not in roles: raise BizError("无权访问", 40300, 403)
        return user
    return _check

# ---- app/core/errors.py：业务异常 → 规范 JSON；堆栈只进日志，永不进响应 ----
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from app.core.logging import log
from app.middleware.trace import current_trace_id

class BizError(Exception):      # 错误码集中定义：40000 业务 / 40100 认证 / 40300 权限 / 40901 设备离线
    code, http_status, message = 40000, 400, "业务错误"
    def __init__(self, message: str | None = None, code: int | None = None, http_status: int | None = None):
        self.message = message or self.message
        self.code, self.http_status = code or self.code, http_status or self.http_status

def envelope(code: int, message: str, data=None) -> dict:
    return {"code": code, "message": message, "data": data, "trace_id": current_trace_id()}

def register_exception_handlers(app: FastAPI) -> None:
    @app.exception_handler(BizError)
    async def _biz(r: Request, e: BizError): return JSONResponse(envelope(e.code, e.message), status_code=e.http_status)
    @app.exception_handler(RequestValidationError)
    async def _bad(r: Request, e: RequestValidationError): return JSONResponse(envelope(42200, "参数校验失败", e.errors()), status_code=422)
    @app.exception_handler(Exception)
    async def _oops(r: Request, e: Exception):
        log.exception("unhandled_error")
        return JSONResponse(envelope(50000, "服务内部错误"), status_code=500)

# ---- app/services/control_service.py + app/adapters/mock_control.py + app/api/routers/control.py ----
from abc import ABC, abstractmethod
from enum import StrEnum

class CommandResult(StrEnum):
    OK = "OK"; OFFLINE = "OFFLINE"; TIMEOUT = "TIMEOUT"; COMMAND_FAILED = "COMMAND_FAILED"
class ControlService(ABC):                   # 上层只认这个接口，不认任何 SDK
    @abstractmethod
    async def send(self, device_id: str, command: str, parameters: dict, request_id: str, timeout: float = 5.0) -> tuple[CommandResult, dict]: ...
class MockControlService(ControlService):     # 离线设备可注入，便于自动化测试
    def __init__(self, offline_ids: set[str] | None = None):
        self.offline_ids = offline_ids or set()
    async def send(self, device_id, command, parameters, request_id, timeout=5.0):
        if device_id in self.offline_ids: return CommandResult.OFFLINE, {}   # 不许假装成功
        return CommandResult.OK, {"echo": {"command": command, "parameters": parameters}}

@router.post("/{device_id}/commands")         # router 只做参数与依赖装配，业务在 service
async def send_command(device_id: str, body: CommandIn, user: User = Depends(require("owner", "member")),
                       svc: ControlService = Depends(get_control_service), db: AsyncSession = Depends(get_db)):
    await device_service.assert_access(db, user.id, device_id)              # 越权校验在 service 层
    result, payload = await svc.send(device_id, body.command, body.parameters, body.request_id, 5.0)
    await command_repo.record(db, user.id, device_id, body, result)         # 留痕，供 ACK 与审计
    if result is CommandResult.OFFLINE: raise BizError("设备离线", 40901, 409)   # TIMEOUT 同法
    return envelope(0, "ok", payload)
```

文件关系：`main.py` 只 import 各 router 与中间件；router 依赖 `api/deps.py` 提供的 `get_db` / `require`；service 依赖 repository 与 `ControlService` 抽象；`adapters/*` 是唯一允许 import 厂家 SDK 或 MQTT 客户端的地方；`core/*` 不 import 任何上层模块。

启动（Ubuntu Bash）：`python -m venv .venv && . .venv/bin/activate` → `pip install fastapi "uvicorn[standard]" "sqlalchemy[asyncio]>=2" asyncpg "pydantic>=2" pydantic-settings pyjwt "passlib[bcrypt]" redis structlog alembic` → `uvicorn app.main:app --reload --port 8000`，最后 `curl -s http://127.0.0.1:8000/health/ready` 期望 `{"status":"ok","pg":true,"redis":true,"mqtt":true}`；Windows PowerShell 把激活行换成 `.venv\Scripts\Activate.ps1`。

## 工程实现要点
### 为什么禁止堆在 main.py
① 无法测试：路由里直接写 SQL 与业务判断，pytest 只能起服务打接口，改一处跑全量。② 无法替换：控制、支付、推送写死在 handler 里，换 Mock、换 SDK 就要改主文件。③ 无法并行：多人改同一文件必然冲突。④ 装配与实现耦合：启动顺序、中间件顺序、依赖注入互相牵制。企业写法是 `main.py` 只保留装配清单，业务在 service，数据访问在 repository，类型与校验在 schema——每层都能单独 import 和单测。

### 认证、权限与校验
- Access Token 15 min、Refresh Token 7 day；刷新即**轮换**，旧 `jti` 写入 Redis 黑名单（TTL = 其剩余有效期），实现登出即失效、被盗可吊销。
- RBAC 三层：平台角色（user / admin）、设备关系（owner / member / viewer）、资源归属。**权限判断必须落在 service 层**——WebSocket、MQTT 回执、后台任务都没有 router。
- 越权（IDOR）防护：查询一律带 `user_id` 条件，查不到返回 404 而非 403，避免泄露"该设备存在"。
- Pydantic 严格模式 `ConfigDict(extra="forbid", str_strip_whitespace=True)`；command 用 `Enum` / `Literal` 收敛，参数用 `Field(ge=..., le=...)` 卡上限，避免 APP 传任意字符串被转发到设备。
- 异步引擎 `create_async_engine(url, pool_size=10, max_overflow=20, pool_pre_ping=True, pool_recycle=1800)`；连接数按 `workers × (pool_size + max_overflow) < PG max_connections`（预留 20% 给运维与 Alembic）核算，宁小勿大：排队优于数据库拒绝服务。
- 事务边界在 service：设备绑定、订单创建、成员权限变更必须同事务；**网络 I/O 不进事务**，否则慢调用长期占住数据库连接。

### 可观测性与健康检查
- `TraceMiddleware` 生成或透传 `trace_id`（上游带 `X-Request-ID` 就沿用），存入 `contextvars`，结构化日志（structlog JSON）自动带上，响应头回写 `X-Trace-ID`；日志只记 ID 与状态，不记 Token、密码、手机号。
- `/health/live` 只查进程（给容器重启判断）；`/health/ready` 逐个探测 PostgreSQL、Redis、MQTT，任一失败返回 503（给负载均衡摘流量）；两者不鉴权但只在内网暴露。
- 默认值：外部 HTTP 连接 3s、读取 5s；控制指令等 ACK 5s；可重试操作指数退避最多 3 次并加抖动；**控制类指令不自动重试**（避免设备收到重复运动指令），由 APP 携带同一 `request_id` 显式重发做幂等。

### WebSocket 推送与前端契约
- 不用 URL query 传 Token（会进 Nginx 访问日志），连接后首帧发送认证消息再入房间；`websocket/manager.py` 维护 `user_id`、`device_id` 两级房间，单用户同设备连接上限 3 条，超限踢最旧。
- 事件名与负载形状与 REST 一致，均带 `trace_id` 与单调递增 `seq`（客户端据此去重与补漏）：`device.state`、`command.ack`、`notification.new`、`order.status`。
- 先提交事务、后发布事件，避免推送成功而落库失败；多实例部署用 Redis Pub/Sub 广播，否则只有持有连接的那个进程收得到。
- 心跳 30s、服务端 90s 无数据即断开；客户端重连退避 1s → 2s → 4s → 8s、上限 30s；重连后先拉一次快照再订阅增量。
- 契约：路径版本化 `/api/v1`；分页统一 `?page=1&page_size=20`（`page_size` 上限 100）且响应含 `total`；错误码由 OpenAPI 枚举定义，前端用 `openapi-typescript` 从 `/openapi.json` 生成 TS 类型。MQTT 主题命名必须与厂家协议文档或 SDK 源码对齐，未拿到文档前一律标 `待核实`，不要自定一套然后当真。

### 学习写法 vs 生产写法
① 初学者把 `SELECT`、业务判断、Token 解析全塞进一个 `@app.post`，因为最快看到结果。② 企业按 `router / service / repository / schema / adapter` 分层：service 不 import FastAPI，repository 不 import 响应模型。③ 差别的原因是变化频率不同——接口形状、存储实现、控制协议各自独立演进，耦合在一起时一个小改动牵动全系统，且无法单测。分层不是形式，是让"换设备 SDK 不动业务代码"真正成立。

### 控制类写操作的安全前置与回滚
顺序固定：Mock 验证状态机与幂等 → 仿真设备或录制回放验证 ACK 与超时 → 真机**低速低力矩**单条指令 → 再放量。前置条件：急停接口独立可用且不依赖 MQTT 通路、指令超时自动停止、设备失联保护已启用。回滚方式：切回 `control_backend=mock` 或关闭控制路由开关；已下发指令必须通过状态查询确认设备真实状态，而不是相信接口返回值。

## 常见坑与验收标准
常见坑：① 把"发布指令成功"当成"设备执行成功"，没有 ACK 与状态回报闭环；② 事务里做网络调用，慢指令拖垮连接池；③ 权限只在前端判断，换个 `device_id` 就能控制别人的设备；④ Refresh Token 过长又不轮换，等于永久凭证；⑤ WebSocket 无背压，客户端断网时服务端内存堆积；⑥ 健康检查恒返回 `ok`，数据库早已断开；⑦ `.env` 进 Git，生产仍开着 `/docs`。

验收项（每条都要跑出结果，不靠感觉）：
1. 无 Token 请求 `/api/v1/devices` → 401；用 A 的 Token 访问 B 的设备 → 403/404，绝不是 200。
2. 拿 Refresh Token 当 Access 用 → 401（`typ` 校验生效）；登出后旧 Token 立即 401（黑名单生效）。
3. Mock 中把设备标为离线再调控制接口 → 返回 `OFFLINE`、HTTP 409，且库里留下一条失败流水。
4. 同一 `request_id` 连发两次控制请求 → 只产生一条 command 记录，第二次返回首次结果（幂等生效）。
5. 停掉 Redis，5s 内 `/health/ready` 变 503、`/health/live` 仍 200；用同一 `trace_id` 能在日志里串起 middleware → router → service → repository → adapter 全链路。
6. 制造未捕获异常，生产配置下响应体只有 code / message / trace_id，无堆栈、无 SQL。
7. 前端 TS 类型由 OpenAPI 生成，改后端字段后 `tsc` 报错，而不是运行时才发现。
8. 用 Locust 压核心读接口与控制接口，记录 QPS、P95/P99、错误率，确认连接池未打满、无慢 SQL；把 `main.py` 的业务逻辑全注释掉，只改一个 router 或 service 就能恢复，说明分层真实存在。

## 学习路径
前置：Python 类型标注与 async/await、HTTP 状态码与 JSON、SQL 增删改查、Git 分支（见 `02-se-foundations.md`）。任一项答不上来先补它，再回来做分层。
1. 先用单文件 FastAPI 跑通一个 CRUD + `/docs`（能解释请求如何变成 SQL），再拆成分层骨架（router / service / repository / schema），业务逻辑一行都不留在 `main.py`。
2. 接 PostgreSQL + SQLAlchemy Async + Alembic，完成迁移与连接池配置。
3. 加 JWT Access + Refresh、RBAC 依赖、统一异常与返回、trace_id 日志。
4. 加 Redis 缓存与分布式锁、Celery / BackgroundTasks、健康检查与 Prometheus 指标。
5. 加 WebSocket 连接管理与事件推送，前端按 OpenAPI 契约生成 TS 类型。
6. 抽 `ControlService`，用 Mock 适配器完成 指令 → ACK → 超时 → 离线 → 幂等 的完整闭环。
7. docker-compose 起 FastAPI + PostgreSQL + Redis + Nginx 并压测（MQTT 先接模拟器，不接真机）；接真机前先过 `08-locomotion-safety.md` 的分级门禁与 `09-production-engineering.md` 的幂等 / 超时 / 降级清单。

完成后你应该能回答：一个控制指令从 APP 点击到设备动作经过哪些模块、在哪一层可能失败、失败时用户看到什么、你如何用 `trace_id` 在日志里定位它。
