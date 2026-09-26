## 是什么与为什么

后端的数据层只回答两个问题：**数据放在哪里、怎么保证它一直是对的**。API 层只回答一个问题：**外部怎么安全、稳定、可预期地读写这些数据**。两者是同一件事的两面——表结构和索引决定了 API 能提供哪些查询，而 API 对幂等与事务的要求，反过来决定表上必须存在哪些唯一约束。

一个请求在这条链路上的流转：`APP → Nginx → FastAPI（router 校验入参）→ service（开事务 / 读缓存 / 发 MQTT）→ repository（SQLAlchemy Async）→ PostgreSQL`，回程是统一响应体（`code / message / data / request_id`）。

最重要的一条约束：**事务里不做网络 IO**。调用设备 SDK、发 MQTT、调支付网关都可能阻塞几百毫秒到数秒，把它们塞进事务会长时间持有行锁和连接，高并发下直接把数据库拖垮。所以事务边界画在 repository 与纯计算之间，一切对外调用移到事务提交之后。

### PostgreSQL 与 MySQL 的选型差异

| 维度 | PostgreSQL | MySQL 8（InnoDB） |
| --- | --- | --- |
| 事务内 DDL | 支持，迁移失败可整体回滚 | DDL 隐式提交，中断后需人工修 |
| 默认隔离级别 | READ COMMITTED | REPEATABLE READ（间隙锁更重） |
| 高级类型 | JSONB、数组、range、原生 uuid | JSON、无数组类型 |
| 索引能力 | 部分索引、表达式索引、GIN/GiST | 前缀索引、函数索引，无部分索引 |
| 建索引 | `CREATE INDEX CONCURRENTLY` 不阻塞写 | Online DDL，行为受算法参数影响 |

结论：本项目选 **PostgreSQL**。设备绑定与权限共享这类关系需要"同一设备只能有一条有效绑定"的约束，在 PG 里一句部分唯一索引就能表达，在 MySQL 里只能用触发器或应用层兜底；JSONB 适合存遥测扩展字段，`timestamptz` 免去时区换算。MySQL 更适合已有 MySQL 运维体系、只做简单 OLTP 的团队。具体版本行为以官方文档为准（例：`CREATE INDEX CONCURRENTLY` 不能在事务块中执行）。

### 为什么用 SQLAlchemy Async / asyncpg

FastAPI 是异步的，但若驱动是同步的（如 psycopg2），每个查询都会占住一个线程，QPS 上不去。`asyncpg` 是原生异步 PostgreSQL 驱动，配合 SQLAlchemy 2.0 的 `AsyncSession` 才能真正不阻塞事件循环。

代价是：**异步代码里漏一个 `await` 就会炸**。最常见的现象是序列化响应时才触发懒加载 IO，报 `MissingGreenlet`。因此约定：模型上不依赖懒加载，关联查询一律显式 `selectinload` / `joinedload`。

### Redis 在这条链路里的两个角色

1. **缓存**：热点读（设备详情、用户简档）扛并发，避免每次打数据库。
2. **协调**：分布式锁、幂等令牌、限流计数、WebSocket 连接映射。

两者都不是"真相来源"。**PostgreSQL 是唯一真相，Redis 丢了可以重建**。任何写操作的正确性必须由数据库约束兜底，而不是由 Redis 里的标记兜底。

## 最小可运行示例

参考组合（写作时点）：Python 3.11、PostgreSQL 16、SQLAlchemy 2.0、asyncpg、Alembic、redis-py 5.x。安装前用 `pip index versions <包名>` 确认当前补丁版本。

### 建表 SQL：用户 / 设备 / 绑定关系

```sql
-- PostgreSQL 16
CREATE TABLE users (
    id            BIGSERIAL PRIMARY KEY,
    phone         VARCHAR(20)  NOT NULL,
    nickname      VARCHAR(32)  NOT NULL DEFAULT '',
    password_hash TEXT         NOT NULL,
    status        SMALLINT     NOT NULL DEFAULT 1,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at    TIMESTAMPTZ                 -- 软删除
);

CREATE TABLE devices (
    id            BIGSERIAL PRIMARY KEY,
    sn            VARCHAR(64)  NOT NULL,      -- 出厂序列号
    model         VARCHAR(64)  NOT NULL,
    firmware_ver  VARCHAR(32),
    online_status SMALLINT     NOT NULL DEFAULT 0,   -- 0 离线 1 在线
    last_seen_at  TIMESTAMPTZ,
    battery       SMALLINT,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE device_bindings (
    id         BIGSERIAL PRIMARY KEY,
    device_id  BIGINT      NOT NULL REFERENCES devices(id),
    user_id    BIGINT      NOT NULL REFERENCES users(id),
    role       VARCHAR(16) NOT NULL DEFAULT 'OWNER',  -- OWNER / MEMBER
    bound_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    unbound_at TIMESTAMPTZ                            -- NULL = 当前有效绑定
);

CREATE UNIQUE INDEX uq_users_phone_active    ON users (phone) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX uq_devices_sn            ON devices (sn);
CREATE UNIQUE INDEX uq_binding_device_active ON device_bindings (device_id) WHERE unbound_at IS NULL;
CREATE UNIQUE INDEX uq_binding_user_device   ON device_bindings (user_id, device_id) WHERE unbound_at IS NULL;
CREATE INDEX idx_binding_user_active ON device_bindings (user_id, bound_at DESC) WHERE unbound_at IS NULL;
CREATE INDEX idx_devices_online      ON devices (last_seen_at DESC) WHERE online_status = 1;
```

### 每个索引的用途与适用查询

| 索引 | 用途 | 适用的查询 |
| --- | --- | --- |
| `uq_users_phone_active` | 手机号唯一，但允许被软删的旧号复用；`WHERE deleted_at IS NULL` 是部分唯一索引，MySQL 无法直接表达 | 注册/登录 `SELECT ... WHERE phone=$1 AND deleted_at IS NULL` |
| `uq_devices_sn` | 序列号全局唯一，是扫码绑定的最终防线；重复绑定由数据库拒绝而非应用判断 | `SELECT ... WHERE sn=$1`（绑定第一步校验） |
| `uq_binding_device_active` | 保证一台设备同一时刻只有一条有效绑定（换绑必须先把旧记录 `unbound_at` 置位） | 防止并发绑定/扫码重复提交造成"一机两主" |
| `uq_binding_user_device` | 同一用户对同一设备只能有一条有效绑定，防重复插入 | 幂等兜底：重复请求撞唯一索引返回 409 |
| `idx_binding_user_active` | 覆盖"我的设备列表"的过滤 + 排序，复合索引最左前缀 `user_id`，`bound_at DESC` 免去排序 | `... WHERE user_id=$1 AND unbound_at IS NULL ORDER BY bound_at DESC LIMIT 20` |
| `idx_devices_online` | 部分索引，只索引在线设备，体量远小于全表，适合运维看板 | `... WHERE online_status=1 ORDER BY last_seen_at DESC LIMIT 50` |

`device_bindings` 上保留外键（数据量小、关系清晰）；`devices.last_seen_at` 这类高频更新的遥测字段不要建普通 B-tree 索引，会放大写开销。

### 异步引擎、迁移与幂等

```python
# app/core/db.py
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

engine = create_async_engine(
    "postgresql+asyncpg://app:pwd@db:5432/appdb",   # db 为 compose 服务名
    pool_size=10,        # 常驻连接：uvicorn worker 数 × 10 ≤ 数据库 max_connections
    max_overflow=20,     # 峰值上限 30；PG 默认 max_connections=100，4 worker 就到 120，必须显式规划
    pool_timeout=5,      # 取不到连接 5s 快速失败，不无限排队
    pool_recycle=1800,   # 30min 回收，规避云数据库空闲断连（厂商默认值待核实）
    pool_pre_ping=True,
    connect_args={"timeout": 5},   # asyncpg 连接超时参数名以官方文档为准
)
SessionLocal = async_sessionmaker(engine, expire_on_commit=False)
```

```bash
# Ubuntu Bash —— Alembic（异步模板）
alembic init -t async migrations            # env.py 需用 connection.run_sync(context.run_migrations)
alembic revision --autogenerate -m "add device_bindings"
alembic upgrade head --sql > review.sql     # 生产先出 SQL 人工审查，再执行
alembic upgrade head
```

```python
# 幂等 + 分布式锁：Redis 走快速路径，唯一索引做最终防线
RELEASE_LUA = "if redis.call('get',KEYS[1])==ARGV[1] then return redis.call('del',KEYS[1]) else return 0 end"

async def bind(session, redis, user_id: int, sn: str, request_id: str):
    # Redis SETNX：同一 request_id 只放行一次，TTL 24h 覆盖重试窗口
    if not await redis.set(f"idem:bind:{request_id}", "1", nx=True, px=86_400_000):
        raise ConflictError("DUPLICATE_REQUEST")
    token = uuid4().hex
    if not await redis.set(f"lock:dev:{sn}", token, nx=True, px=10_000):
        raise BusyError("BINDING_IN_PROGRESS")     # 拿不到锁立即失败，不阻塞请求
    try:
        async with session.begin():                # 事务内只做数据库操作
            device = await repo.get_by_sn(session, sn, for_update=True)
            ...                                    # 写 device_bindings，撞唯一索引则回滚
    finally:
        await redis.eval(RELEASE_LUA, 1, f"lock:dev:{sn}", token)   # 校验 token 再删，避免删掉别人的锁
```

## 工程实现要点

### 分层与事务边界

- 事务只在 service 层开启：`async with SessionLocal() as s, s.begin():`；repository 只接收 `session`，**绝不自己 commit**，否则事务被切碎、回滚失效。
- 事务尽量短：只包住必要的写；发 MQTT、调 SDK、写文件、调第三方支付都放到 `begin()` 之后。
- 关键写操作（订单创建、支付回调、设备绑定、权限变更）必须在一个事务内完成"状态校验 + 写入 + 关联更新"。

### 锁与并发

| 场景 | 做法 | 说明 |
| --- | --- | --- |
| 并发改同一行（如设备昵称） | 乐观锁：`UPDATE ... SET version=version+1 WHERE id=:id AND version=:v`，影响行数为 0 即冲突 | 无锁等待，冲突时提示重试 |
| 必须串行的临界区 | 悲观锁 `SELECT ... FOR UPDATE`（PG 可加 `NOWAIT` 立即失败） | 一定要在同一事务内，且加锁顺序统一按 id 升序 |
| 任务队列取单 | `FOR UPDATE SKIP LOCKED` | 多 worker 并行消费互不阻塞 |
| 死锁 | 捕获数据库死锁错误（PG SQLSTATE `40P01`、MySQL 1213，以官方错误码文档为准），整体重试上限 3 次 | 死锁根因几乎都是加锁顺序不一致 |

Redis 分布式锁的边界：单实例 `SET NX PX` 够用；Redlock 在故障切换下的正确性存在公开争议，跨机房强一致场景应改用数据库约束或带 fencing token 的方案。

### 缓存策略（含穿透 / 击穿 / 雪崩）

| 问题 | 成因 | 处理 |
| --- | --- | --- |
| 缓存穿透 | 查询不存在的 key，请求全打到库 | 空值缓存 TTL 60s + 布隆过滤器拦截明显不存在的设备号 |
| 缓存击穿 | 热点 key 过期瞬间大量并发回源 | 单飞（singleflight）：用 `SET NX` 只放一个请求回源，其余短暂等待或返回旧值 |
| 缓存雪崩 | 大批 key 同时过期或 Redis 故障 | TTL 加 ±10% 随机抖动；分级超时与熔断降级；缓存不可用时直连库并降级非核心字段 |

一致性默认用 **Cache-Aside**：先写数据库、提交后再删除缓存（不是更新缓存），并给缓存设 TTL 兜底。反过来"先删缓存再写库"在并发下更容易读到旧值。缓存读超时给 200–500ms，失败即降级走数据库，绝不让缓存故障拖死接口。

### RESTful 与统一响应

- 资源用复数名词：`/api/v1/devices/{device_id}/bindings`；动作类接口才用动词，如 `/devices/{id}:control`（或 `POST /devices/{id}/commands`）。
- 方法语义：`GET` 幂等只读、`POST` 创建（返回 201）、`PUT` 全量替换、`PATCH` 局部更新、`DELETE` 删除（204）。
- 状态码：400 参数格式错、401 未认证、403 无权限、404 不存在、409 冲突/重复、422 校验失败、429 限流、500 服务端异常、503 依赖不可用。
- 统一响应体：`{"code": "OK", "message": "", "data": {...}, "request_id": "..."}`；错误用业务错误码字符串而非裸数字，便于前端分支与日志检索。设备控制类必须能明确返回 `OFFLINE` / `TIMEOUT` / `COMMAND_FAILED`，**离线时不得返回成功**。生产环境禁止返回堆栈。

### 分页与版本管理

- 默认 `limit=20`，上限 100（防止一次拉全表）；页码分页只用于后台导出等浅分页场景。
- C 端列表用**游标分页**：`WHERE (bound_at, id) < (:cursor_ts, :cursor_id) ORDER BY bound_at DESC, id DESC LIMIT 20`，避免 `OFFSET 100000` 越翻越慢。
- API 版本用 URL 前缀 `/api/v1`，破坏性变更升 `v2`，旧版本给明确下线时间。注意：**接口版本与 Alembic 数据库迁移版本是两件事**，各自独立演进，不要用同一套号。

### 慢 SQL 定位

1. 开日志：PG `SET log_min_duration_statement = '200ms'`（会话级临时开，别全局常开）、装 `pg_stat_statements` 排序看总耗时；MySQL 开 `slow_query_log`、`long_query_time=0.2`。
2. 看计划：PG `EXPLAIN (ANALYZE, BUFFERS)`；MySQL `EXPLAIN ANALYZE`（8.0.18 起，具体小版本以官方文档为准）。
3. 判断：出现 `Seq Scan` 大表全扫、`rows` 估算与实际差几个数量级、排序走磁盘，通常是缺索引、索引失效（函数包裹列、隐式类型转换）或统计信息过期（`ANALYZE`）。
4. 复查：改完索引再用同一 SQL 验证，并确认写放大可接受。

## 常见坑与验收标准

### 学习写法 vs 生产写法

① **初学者为什么这样写**：`session.add()` 后随手 `commit()`，用 `try/except Exception` 一把抓，SQL 里拼字符串，`SELECT *` 全查出来再在 Python 里过滤，`create_all()` 建表。
② **企业怎么写**：事务由 service 层显式划定并整体回滚；异常按业务错误码分类上抛，由全局处理器统一转 JSON；查询用参数绑定 + 显式列；过滤排序交给 SQL 并配索引；schema 变更走 Alembic 版本化迁移。
③ **差异原因**：把 `commit` 散落在各处会导致业务失败时数据半写；字符串拼 SQL 直接带来注入风险；Python 侧过滤把数据库的索引能力浪费掉，数据量一涨就崩；`create_all` 无法表达变更历史，多环境无法对齐、无法回滚。

### 常见坑

- 漏 `await` 导致 `MissingGreenlet`；响应模型里访问未加载的关联字段同样触发。
- 连接池总量算错：`worker 数 × (pool_size + max_overflow)` 超过 `max_connections`，高峰期报 `too many clients`。
- 长事务：事务里 await 外部 HTTP / MQTT，锁持有到超时，`idle_in_transaction_session_timeout` 建议设 60s（PG 默认 0，即不限制）。
- 用 `DELETE` 物理删用户，导致历史订单外键断裂；软删除要记得所有查询都带 `deleted_at IS NULL`（可用视图或统一的 repository 基类兜底）。
- 迁移里给大表加非空列且无默认值，长时间锁表；应分步：加可空列 → 回填 → 加约束。
- 幂等只靠 Redis：Redis 抖动或过期后重复请求穿透，必须叠加数据库唯一索引。

### 验收标准（能通过才算会了）

- [ ] 用 `EXPLAIN` 证明"我的设备列表"查询走的是 `idx_binding_user_active` 而非全表扫描。
- [ ] 并发发起两个相同 `request_id` 的绑定请求，只有一个成功，另一个返回 409/`DUPLICATE_REQUEST`。
- [ ] 两台并发设备绑定同一台设备，数据库层保证只有一条有效绑定（验证 `uq_binding_device_active` 生效）。
- [ ] 关停 Redis，核心读接口仍可用（降级直连数据库），只是变慢；核心写接口不因锁失败而误报成功。
- [ ] `alembic upgrade head` → `alembic downgrade -1` → 再 `upgrade head`，schema 能往返，应用可启动。
- [ ] 人为制造死锁，服务能捕获并按上限 3 次重试，最终返回明确错误码而不是 500 空响应。

## 学习路径

前置：SQL 基础、事务 ACID 与隔离级别、HTTP 方法与状态码、Python 类型标注与 async/await。顺序：① 建表与索引并用 `EXPLAIN` 验证 → ② SQLAlchemy 2.0 声明式模型 + `AsyncSession` 增删改查 → ③ Alembic 首次迁移与回滚演练 → ④ 统一响应体与全局异常处理 → ⑤ 游标分页与接口幂等（唯一索引 + Redis）→ ⑥ 缓存三件套与分布式锁 → ⑦ 事务边界、锁与并发压测（Locust 观察 P95/P99 与慢 SQL）→ ⑧ 索引调优与慢查询复盘。

里程碑：能独立设计一张带约束与索引的业务表；能解释每条索引服务哪条查询；能在压测下定位到具体 SQL 而不是"感觉慢"；能在不破坏数据的前提下完成一次线上迁移。
