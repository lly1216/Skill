# 生产级可靠性

## 是什么与为什么

**可靠性不是"代码没 bug"，而是"依赖坏了系统还能给出正确答案"。** 生产里必然发生：网络抖动、对端超时、连接池打满、Redis 重启、MQTT 断连、设备离线、用户连点两次"前进"。可靠性工程就是为这些必然事件预先定义**返回值语义**与**失败路径**。

一次远程控制命令的链路：`APP → Nginx → FastAPI(router) → ControlService → MQTT/SDK Adapter → 设备`，旁路写入 `PostgreSQL/Redis`，全程携带 `trace_id` 与指标。这条链路有 6 个会失败的点，每个点只有三种诚实结果：**成功、明确失败、明确"未知/受理中"**。可靠性工作就是把"未知"压缩到最小，并且**绝不允许把"未知"写成"成功"**。

### 五道防线（顺序固定，不可跳级）
1. **超时**：先保证自己不被拖死。没有超时的调用不是"更宽容"，是把故障传染给整个进程。
2. **重试**：只对**幂等**操作、**可恢复**错误，且有**次数上限 + 退避 + 抖动**。
3. **熔断**：连续失败后快速失败，不再消耗连接与时间。
4. **降级**：读接口可返回旧快照（显式标 `stale`）；**写接口与控制指令禁止降级为"假成功"**。
5. **隔离（舱壁）**：不同下游用独立连接池/并发额度/队列，一个下游挂掉不拖垮其他业务。

### 设备离线必须说"离线"
`ControlService` 的返回值是可靠性设计的核心契约：**离线 = `OFFLINE`，ACK 未回 = `TIMEOUT`，设备回 NACK = `COMMAND_FAILED`**。三者都不能映射成 HTTP 200 + "操作成功"，也不许"先乐观返回成功、后台再补救"。

## 最小可运行示例

依赖：`fastapi / uvicorn[standard] / structlog / tenacity / redis / prometheus-client / locust`。版本先核实再锁定（`pip index versions <包名>` 或 PyPI 页面），不要抄旧教程里的版本号。

### 1. 未捕获异常统一 JSON，生产不泄漏堆栈
```python
# app/middleware/errors.py
import logging
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
logger = logging.getLogger(__name__)

def _env(code: str, message: str, trace_id: str, detail=None) -> dict:
    return {"ok": False, "code": code, "message": message, "trace_id": trace_id, "detail": detail}

def register_exception_handlers(app: FastAPI, *, debug: bool) -> None:
    @app.exception_handler(RequestValidationError)
    async def validation_exc(request: Request, exc: RequestValidationError):
        tid = getattr(request.state, "trace_id", "-")
        # 只回字段级错误，不回整个请求体（可能含 token / 隐私）
        errs = [{"loc": list(e["loc"]), "msg": e["msg"]} for e in exc.errors()]
        return JSONResponse(422, _env("VALIDATION_ERROR", "参数校验失败", tid, errs))

    @app.exception_handler(Exception)
    async def unhandled(request: Request, exc: Exception):
        tid = getattr(request.state, "trace_id", "-")
        logger.exception("unhandled_exception", extra={"trace_id": tid, "path": request.url.path})
        detail = f"{type(exc).__name__}: {exc}" if debug else None   # 生产 debug=False
        return JSONResponse(500, _env("INTERNAL_ERROR", "服务器内部错误", tid, detail))
```
`debug` 来自 `app/core/config.py` 的 `Settings`（`.env.dev` 为 true，`.env.prod` 为 false）。还要单独覆盖 `StarletteHTTPException` 与 404/405，否则错误响应格式不统一。**验证方式：`curl -i` 一个必崩的测试路由，响应体不得出现 `Traceback`、文件路径、SQL。**

### 2. 离线不得假装成功：契约 + 返回结构
```python
# app/schemas/control.py
from datetime import datetime
from enum import Enum
from pydantic import BaseModel
class ControlStatus(str, Enum):
    ACCEPTED = "ACCEPTED"              # 已下发，结果未知（等 ACK）
    SUCCEEDED = "SUCCEEDED"            # 设备 ACK 确认完成
    OFFLINE = "OFFLINE"                # 设备离线，指令根本没发出去
    TIMEOUT = "TIMEOUT"                # 已下发，ACK 超时未回
    COMMAND_FAILED = "COMMAND_FAILED"  # 设备明确回 NACK / 拒绝执行
    REJECTED = "REJECTED"              # 服务端前置校验不通过（越权、参数非法）

class ControlResult(BaseModel):
    # ok 仅在 status == SUCCEEDED 时为 True；ACCEPTED 也是 False —— "已受理"不等于"控制成功"。
    ok: bool
    status: ControlStatus
    code: str                                  # DEVICE_OFFLINE / DEVICE_TIMEOUT / COMMAND_FAILED
    message: str
    request_id: str
    device_id: str
    retriable: bool                            # 能否用同一 request_id 重试
    device_last_seen: datetime | None = None   # 离线判定的依据，便于自证
    latency_ms: int
```
入参 `ControlCommand` 固定含 `device_id / command / parameters / request_id / timestamp`；`request_id` 由客户端生成，服务端用它做幂等键。下表是推荐映射，也可选"永远 200 + 业务码"，但必须全项目统一并写进 API 文档，两种混用是控制类接口最危险的坑。

| status | HTTP | code | ok | 客户端动作 |
|---|---|---|---|---|
| ACCEPTED | 202 | COMMAND_ACCEPTED | false | 提示"已下发，等待确认"，用 WebSocket 取最终结果 |
| SUCCEEDED | 200 | OK | true | 提示成功 |
| OFFLINE | 409 | DEVICE_OFFLINE | false | 提示离线，提供"上线后重发"（同 request_id） |
| TIMEOUT | 504 | DEVICE_TIMEOUT | false | 提示超时，**先查状态再决定重发**，禁止自动连点 |
| COMMAND_FAILED | 502 | COMMAND_FAILED | false | 展示设备返回的原因，禁止自动重试 |
| REJECTED | 403/422 | PERMISSION_DENIED / VALIDATION_ERROR | false | 修正后由用户重新发起（换新 request_id） |

## 工程实现要点

### 事务边界
一个用例一个事务，边界写在 `services/` 层；`repositories/` 只管单条读写、不自己 `begin()`，避免嵌套事务语义混乱。
事务内**只做数据库操作**——禁止在事务里发 HTTP、发 MQTT、跑长计算，否则长事务持锁、连接池被打满。"落库 + 发消息"改用**事务性发件箱（outbox）**：同事务写 `outbox` 表，独立任务再投递并标记已发；隔离级别用数据库默认的 READ COMMITTED，需要更严时把 `serialization_failure` 的重试做在**整个事务**外层。必须走事务的关键写：订单创建、支付回调、设备绑定、权限变更、控制指令入库。

### 幂等三件套的取舍
| 手段 | 适合 | 代价 / 限制 |
|---|---|---|
| `request_id` + Redis | 控制指令、支付回调、跨服务调用 | 依赖 Redis 可用；只在 TTL 内幂等（建议 24h） |
| 数据库唯一索引 | 订单、绑定关系、支付单号等落库写 | 需自然唯一键；冲突要转成"已存在同一结果"而非 500 |
| 前置状态校验（状态机） | 与上面叠加使用 | 单独用挡不住并发双击 |

**落地组合**：落库写 = **唯一索引兜底 + `request_id` 返回一致响应**；纯外发控制指令 = **`request_id` + Redis 记 `cmd:{device_id}:{request_id}` → 结果，TTL 24h**。Redis 不可用时写入仍由唯一索引保证不重复，控制指令**快速失败**，绝不无幂等地重发。

### 超时默认值与依据
| 调用 | 默认值 | 依据 |
|---|---|---|
| 外部 HTTP 连接 | 3s | 同机房建连正常 <50ms，3s 已含 DNS + TLS 约 60 倍余量，再大无意义 |
| 外部 HTTP 读取 | 5s | 覆盖对端 p99，且必须小于上游自己的超时，形成递减超时链 |
| 数据库语句 | 读 3s / 批处理 10s | 读超过 3s 基本是缺索引；批处理放后台任务 |
| Redis socket | 0.5s | 它是缓存不是账本，慢就等于不可用，必须立刻回源 |
| MQTT publish ACK / 设备 ACK | 2s / 3–5s | 前者只代表 broker 收到、不代表设备执行；后者**待核实**，以厂家 SDK/协议文档时序为准（常见做法：控制周期 × N + 网络往返） |

超时链示例：客户端 20s → Nginx `proxy_read_timeout 15s` → 网关 10s → 本服务上游调用 8s（连接 3s + 读取 5s）→ DB 语句 3s。**任何一层超时必须小于其调用方**，否则调用方先放弃，重试会造成重复执行。

### 指数退避重试（上限 3 次 + 抖动）
```python
# app/core/retry.py
async def retry_async(op, *, attempts: int = 3, base: float = 0.5,
                      factor: float = 2.0, max_sleep: float = 5.0):
    for i in range(attempts):
        try:
            return await op()
        except Exception as exc:                # 生产里换成明确的可重试异常集合
            if not _is_retryable(exc) or i == attempts - 1:
                raise
            delay = min(max_sleep, base * factor ** i)
            await asyncio.sleep(random.uniform(0, delay))   # full jitter，避免重试风暴
```
可重试：连接失败、超时、429、502/503/504、`serialization_failure`。**不可重试**：400/401/403/404、业务校验失败、未加幂等键的非幂等写。三次等待上限约 0.5+1+2 = 3.5s（含抖动），总预算仍要在调用方超时内。指令级重试以 `ControlResult.retriable` 为准，不靠猜。

### 熔断与降级
熔断器是一个三态机：**关闭**（正常调用，统计连续失败）→ **打开**（直接抛 `CircuitOpenError`，不占连接、不等待）→ **半开**（冷却结束后只放一个探测请求，成功则关闭，失败则重新计时）。
参数依据：**连续 5 次失败 + 冷却 30s** 是保守起点——阈值太低会被偶发抖动误触发，太高就失去保护意义；必须按**时间窗内失败率或连续失败数**统计，不能用"累计失败总数"（低频业务永远触发不了）。熔断粒度按下游实例或服务划分，不要全局一个开关。需要现成实现时再评估库，**以 PyPI 当前维护状态为准**。
降级：读接口可回源、可返回旧快照但必须带 `stale: true` 与快照时间；视频/轨迹类可降清晰度或暂关；**写与控制指令不降级**，只有成功或明确失败。降级开关集中配置、可运行时关闭非核心模块，控制通道与健康检查保持存活。

### 可观测性
- **日志**：`structlog` 输出 JSON，字段固定 `ts/level/event/trace_id/request_id/user_id/device_id/path/latency_ms/status`；只记"发生了什么"，不记密码、token、完整请求体。
- **trace_id**：入口中间件生成或透传 `X-Request-ID`，存 `contextvars`，注入日志与响应头，跨服务用请求头传播。
- **指标**：`/metrics` 暴露请求计数与耗时直方图（用 `prometheus-fastapi-instrumentator` 时默认名 `http_request_duration_seconds`，**以本机 `/metrics` 实际输出为准**）、`control_command_total{status=...}`、设备在线/离线数、DB 连接池使用率、Redis/MQTT 连接状态。
- **健康检查**：`/health` 逐项探测 PostgreSQL（`SELECT 1`）、Redis（`PING`）、MQTT（连接与最近心跳），任一项异常返回 503 并标明 `component`，不要只回静态 `{"status":"ok"}`。
- **告警规则**（指标名必须与代码注册的一致）：
```yaml
groups:
  - name: api-slo
    rules:
      - alert: HighErrorRate        # 5xx 占比 >1%（持续 5 分钟）
        expr: sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m])) > 0.01
        for: 5m
        labels: {severity: critical}
      - alert: HighLatencyP95       # P95 > 500ms（持续 10 分钟）
        expr: histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le)) > 0.5
        for: 10m
        labels: {severity: warning}
```
再加两条：设备离线率 `sum(devices_offline)/sum(devices_total) > 0.3`（持续 5 分钟），以及 PostgreSQL/Redis/MQTT 探活失败（持续 1 分钟）。阈值依据：5xx > 1% 说明有真实缺陷；P95 > 500ms 是 C 端接口的体感边界；离线率 > 30% 通常是 MQTT 或网络侧故障而非单机问题。Grafana 看板至少四行：**流量与错误率、延迟分位（P50/P95/P99）、设备在线率与控制指令状态分布、资源（DB/Redis/CPU/连接池）**。

### 高并发
- `async/await` 全链路：禁止在 `async def` 里用阻塞库（`requests`、同步 DB 驱动、`time.sleep`），一个阻塞调用会卡住整个事件循环；不可异步的 SDK 用 `run_in_threadpool` 或独立线程池兜住。
- 连接池：`create_async_engine(..., pool_size=10, max_overflow=20, pool_pre_ping=True, pool_recycle=1800)`；**进程数 × (pool_size + max_overflow) 必须小于数据库 `max_connections`**，否则高峰期报连接拒绝。
- Redis 两件事分开用：**缓存**（热点状态，TTL 加随机抖动防雪崩，空结果短 TTL 防穿透，热点键用单飞/互斥锁防击穿）与**分布式锁**（`SET key token NX PX 30000` + Lua 比对 token 释放，只用于必须互斥的短操作，**不能替代事务与唯一索引**）。
- 消息队列：通知、图片处理、OTA 分发交给 Celery/后台任务，按业务拆队列并设优先级，控制通道不被社区/商城挤压。
- Nginx 限流：`limit_req_zone $binary_remote_addr zone=api:10m rate=20r/s;` 配 `limit_req zone=api burst=20 nodelay;`，控制类接口用更严的独立 zone，并设 `limit_conn`。
- WebSocket：每实例连接数上限按内存与 FD 实测设定，心跳清理僵尸连接；多实例跨节点推送必须经 Redis Pub/Sub 或 MQTT 广播，否则用户连到 B 实例收不到 A 实例的推送。
- 水平扩展：服务无状态（会话与状态外置到 Redis/DB），扩副本即可；**MQTT broker、数据库、Redis 等有状态组件的扩容方式完全不同**，需单独设计。

### 压测（Locust）
```python
# tests/load/locustfile.py   启动：locust -f locustfile.py --host=http://127.0.0.1:8000
from locust import HttpUser, task, between
class ApiUser(HttpUser):
    wait_time = between(0.5, 2.0)
    @task(3)
    def status(self): self.client.get("/api/v1/devices", name="/devices")
    @task(1)   # 每次新 request_id 才真正压到控制链路；压幂等要另写固定 id 场景
    def command(self):
        self.client.post("/api/v1/devices/demo/commands", name="/commands", json={
            "device_id": "demo", "command": "stand", "parameters": {},
            "request_id": str(uuid4()), "timestamp": datetime.now(timezone.utc).isoformat()})
```
读结果的方法：先看**错误率**（>1% 就停下查原因，别继续加压）；再看 **P95/P99**（两者差距大 = 长尾，通常是锁、冷查询或缓存击穿）；最后看 **QPS 拐点**（QPS 不再上升而延迟暴涨 = 已到瓶颈，继续加压无意义）。慢接口对应慢 SQL：
```sql
-- PostgreSQL；需在 postgresql.conf 设 shared_preload_libraries='pg_stat_statements' 并重启
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SELECT query, calls, round(mean_exec_time::numeric,2) AS avg_ms
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;  -- 列名随版本变化（PG13 前为 total_time）
```
定位到 SQL 后用 `EXPLAIN (ANALYZE, BUFFERS)` 看真实行数与索引使用，形成"压力 → 指标 → SQL → 索引/代码"的闭环；压测数据量与索引必须接近生产，否则结论不可用。

### 前置验证与回滚（设备动作 / 生产写 / 删除）
1. 先用 `MockControlService` 跑通全流程与返回契约，必须覆盖 OFFLINE / TIMEOUT / COMMAND_FAILED 三条失败路径。
2. 再接 MQTT 模拟器（**topic 名与报文格式待核实**：以厂家协议文档或现有设备抓包为准），确认 ACK 时序与超时阈值。
3. 真机走"只读验证（读状态、读电量）→ 单条低风险指令 → 分级安全门禁"，见 `08-locomotion-safety.md`。
4. 回滚方式：控制指令必须预留**急停/反向指令**且优先级高于普通指令；生产写靠事务回滚或反向补偿任务；删除类先软删除。

### 学习写法 vs 生产写法
① 初学者：`except Exception: pass`、外部调用不设超时、`while True` 重试、异常直接 `return {"msg": str(e)}`。
② 企业：全局兜底 handler + 精确捕获、所有外部调用显式超时、有界重试 + 抖动 + 熔断、错误码机器可读且与 HTTP 状态对齐。
③ 原因：吞异常丢可观测性并把错误推给下游；**异步服务里一个无超时调用就能拖死事件循环**；无限重试会打垮已过载的下游；把 `str(e)` 返回客户端等于把内部结构与 SQL 暴露给攻击者。

## 常见坑与验收标准

### 常见坑
- 事务里发 MQTT/HTTP：事务回滚了，设备其实已收到指令，本地状态与设备不一致。
- 生产 `debug=True` 把堆栈随 500 返回；或 Nginx `error_page` 覆盖了 JSON 响应；或只加了统一 `Exception` handler 却忘了 404/405。
- 幂等只靠 Redis：Redis 未持久化重启后重复下单；或唯一索引冲突直接抛 500 而不是返回"已存在"。
- 重试没加抖动，下游恢复瞬间被所有实例同时重试打死（重试风暴）。

### 验收标准（逐条可验证）
- [ ] `curl -i` 一个必崩路由：统一 JSON、有 `trace_id`、无堆栈与文件路径；同一次请求能在日志里用 `trace_id` 查到完整堆栈。
- [ ] 断开 MQTT 或把设备标为离线：控制接口返回 `OFFLINE`、`ok=false`、`retriable` 明确，且**设备未收到任何指令**。
- [ ] 同一 `request_id` 连发 10 次控制指令，设备侧只收到 1 次且 10 次响应体完全一致；同一订单 `request_id` 并发提交 20 次，数据库只有 1 条记录，冲突请求返回"已存在"而非 500。
- [ ] 把外部依赖指向只挂起不响应的假服务：3s/5s 内返回超时错误，进程内存与连接池无持续增长；连续 5 次失败后熔断生效，响应时间降到毫秒级。
- [ ] 重试日志显示退避递增且带抖动，最多 3 次，第 3 次后立即失败。
- [ ] 停掉 Redis：`/health` 返回 503 并指出失败组件；恢复后自动回到 200。
- [ ] Locust 报告能同时给出 QPS、P95、P99、错误率，并能用 `pg_stat_statements` 指出最耗时的 3 条 SQL 及索引改进方案。

## 学习路径
前置：`03-app-web-backend.md`（分层与统一返回）、`04-data-api.md`（事务/索引/Redis）、`05-server-ops.md`（Nginx/Compose/监控）。顺序：统一异常与 trace_id → 超时与有界重试 → 幂等三件套 → 事务边界与 outbox → 熔断与降级 → 指标与告警 → 高并发与压测 → 故障演练（主动断 Redis/MQTT/DB 各一次并记录系统行为）。
里程碑：能独立写出"设备离线返回 OFFLINE 而不是假成功"的完整接口，并用压测与指标证明它在过载下快速失败、不扩散故障。
