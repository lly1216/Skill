# 服务器与运维部署

## 是什么与为什么

上线是把裸机变成**可重复、可回滚、可观测**的运行环境，而不是"把代码拷上去跑起来"：

```
公网 → 安全组/ufw → Nginx(80/443, TLS 终止) → FastAPI 进程
                                                ├→ PostgreSQL
                                                ├→ Redis
                                                ├→ MQTT Broker → 设备
                                                └→ /metrics ← Prometheus → Grafana 告警
```

- **SSH 密钥 + 防火墙 + 最小权限**：把"谁能进服务器"从"知道密码即可"收敛到"持有私钥且被显式授权"——公网机器被扫端口、被爆破是常态而非意外。
- **Nginx 与进程模型**：Nginx 是唯一暴露公网的进程（TLS 终止、静态资源、限流、上传体积上限、WebSocket 升级）；Gunicorn 是主进程（master），fork 并守护 worker、崩溃自动重启，Uvicorn 提供 ASGI 能力。多进程 + 每进程一个事件循环，才吃得满多核。
- **Docker Compose + .env 隔离**：把"服务器上装了什么版本"变成可提交、可 review、可复现的 YAML，消灭环境漂移；同一镜像在 dev/staging/prod 只靠注入环境变量而变，不改代码也不改镜像。
- **CI/CD + 灰度回滚**：构建、测试、打镜像、发布变成不可绕过的一致流水线，人只审批不手工操作；新版本先接 5% 流量，异常时切回上一个镜像 tag 而不是上服务器改代码。
- **备份与恢复演练**：只有演练过能恢复的备份才算备份。**Prometheus/Grafana + 日志集中化**则回答"哪层坏了、从何时开始、影响多少请求"，靠指标和带 trace_id 的日志，不靠 `docker logs` 翻屏。

## 最小可运行示例

未标注处均为 **Ubuntu Bash（22.04/24.04 LTS）**。

### 1) 初始化与安全加固

```bash
adduser deploy && usermod -aG sudo deploy && usermod -aG docker deploy
ssh-keygen -t ed25519 -C "deploy@laptop" -f ~/.ssh/dog_prod      # 本地生成密钥
ssh-copy-id -i ~/.ssh/dog_prod.pub deploy@<服务器IP>
```

`/etc/ssh/sshd_config` —— **必须先验证密钥能登录再关密码登录，并保留一个已登录会话，否则会把自己锁在外面**：

```
PasswordAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 20
```

```bash
sudo sshd -t && sudo systemctl reload ssh           # 先语法检查再 reload
sudo ufw default deny incoming && sudo ufw default allow outgoing
sudo ufw allow 22/tcp && sudo ufw allow 80/tcp && sudo ufw allow 443/tcp
sudo ufw enable && sudo ufw status verbose
# fail2ban 类思路：5 分钟内 SSH 失败 5 次封 1 小时
sudo apt-get install -y fail2ban   # [sshd] maxretry=5 findtime=10m bantime=1h
```

### 2) Docker Compose 多服务编排

目录：`deploy/{docker-compose.yml,docker-compose.prod.yml,nginx/,prometheus/,scripts/,mosquitto/}`；只提交 `.env.example`，`.env.dev/.env.staging/.env.prod` 进 `.gitignore`。

```yaml
# deploy/docker-compose.yml —— FastAPI + PostgreSQL + Redis + Nginx + MQTT
name: dog-backend
x-restart: &restart { restart: unless-stopped }
x-env:     &env     { env_file: [".env.${APP_ENV:-dev}"] }
services:
  api:
    <<: [*restart, *env]
    build: { context: .., dockerfile: Dockerfile }
    image: registry.example.com/dog/api:${IMAGE_TAG:?IMAGE_TAG required}
    environment:
      DATABASE_URL: postgresql+asyncpg://dog:${POSTGRES_PASSWORD}@postgres:5432/dog
      REDIS_URL: redis://redis:6379/0
      MQTT_HOST: mqtt
      MQTT_PORT: "1883"
    expose: ["8000"]        # 只在内网暴露；依赖服务一律 expose，绝不 ports 到宿主机
    depends_on:
      postgres: { condition: service_healthy }
      redis:    { condition: service_healthy }
      mqtt:     { condition: service_started }
    healthcheck:            # 必须含依赖状态；其余服务同法，间隔 10s、重试 5、超时 5s
      test: ["CMD", "python", "-c", "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=3)"]
      interval: 15s
      timeout: 5s
      retries: 3
      start_period: 30s
    logging: { driver: json-file, options: { max-size: "50m", max-file: "5" } }
    stop_grace_period: 30s  # 必须大于 gunicorn graceful_timeout
  postgres:
    <<: [*restart, *env]
    image: postgres:16
    expose: ["5432"]
    volumes: ["pg_data:/var/lib/postgresql/data"]
    healthcheck: { test: ["CMD-SHELL", "pg_isready -U dog -d dog"], interval: 10s, timeout: 5s, retries: 5 }
  redis:
    <<: *restart
    image: redis:7
    command: ["redis-server", "--appendonly", "yes", "--maxmemory", "512mb", "--maxmemory-policy", "allkeys-lru"]
    expose: ["6379"]
    volumes: ["redis_data:/data"]
    healthcheck: { test: ["CMD", "redis-cli", "ping"], interval: 10s, timeout: 3s, retries: 5 }
  mqtt:
    <<: *restart
    image: eclipse-mosquitto:2    # 配置文件只读挂载；小版本以官方 tags 为准（待核实）
    expose: ["1883", "9001"]
    volumes: ["./mosquitto/mosquitto.conf:/mosquitto/config/mosquitto.conf:ro", "mqtt_data:/mosquitto/data"]
  nginx:
    <<: *restart
    image: nginx:1.27-alpine
    ports: ["80:80", "443:443"]   # 全栈唯一对外端口
    volumes: ["./nginx/conf.d:/etc/nginx/conf.d:ro", "./certs:/etc/nginx/certs:ro", "static_data:/var/www/static:ro"]
    depends_on: [api]
# deploy/docker-compose.prod.yml 用 -f 叠加声明差异：APP_ENV/LOG_LEVEL、资源 limits、pg 参数。
volumes: { pg_data: {}, redis_data: {}, mqtt_data: {}, static_data: {} }
```

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml --env-file .env.prod up -d
docker compose ps && docker compose logs -f --tail=100 api
```

### 3) Nginx 反代 + WebSocket（`deploy/nginx/conf.d/api.conf`）

```nginx
upstream fastapi_upstream { server api:8000 max_fails=3 fail_timeout=10s; keepalive 32; }
limit_req_zone $binary_remote_addr zone=api_rl:10m rate=10r/s;   # 控制类接口限流
server { listen 80; server_name api.example.com; return 301 https://$host$request_uri; }
server {
    listen 443 ssl; http2 on; server_name api.example.com;
    ssl_certificate /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;  ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 20m;     # 社区图片/视频上传上限，按业务调整
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    location /static/ { alias /var/www/static/; expires 7d; add_header Cache-Control "public, immutable"; }
    location /ws/ {               # WebSocket 必须显式升级
        proxy_pass http://fastapi_upstream;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;  proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;  # 取应用心跳 30s 的 10 倍
    }
    location /api/v1/control/ {
        limit_req zone=api_rl burst=20 nodelay; limit_req_status 429;
        proxy_pass http://fastapi_upstream;  proxy_set_header X-Request-ID $request_id;
        proxy_connect_timeout 3s; proxy_read_timeout 10s;
    }
    location / {   # 其余接口同形：proxy_pass + Host/X-Forwarded-Proto/X-Request-ID，read_timeout 30s
        proxy_pass http://fastapi_upstream;
        proxy_set_header Host $host;  proxy_set_header X-Forwarded-Proto $scheme;
    }
    location /metrics { deny all; }   # 指标只给内网 Prometheus 抓
}
```

### 4) Gunicorn + Uvicorn（`gunicorn.conf.py`）

```python
import multiprocessing
bind, worker_class = "0.0.0.0:8000", "uvicorn.workers.UvicornWorker"
workers = min(4, multiprocessing.cpu_count() * 2 + 1)  # 异步应用取 2*CPU+1，上限 4
timeout, graceful_timeout = 30, 30                     # timeout 须大于最慢接口 P99
max_requests, max_requests_jitter = 1000, 100          # 防长跑内存缓慢泄漏
accesslog, loglevel, forwarded_allow_ips = "-", "info", "*"   # 信任 Nginx 的 X-Forwarded-*
```

master 收到 `SIGTERM` 后转发给 worker：worker 停止接新连接、处理完在途请求再退出。滚动发布依赖这个行为，所以 `stop_grace_period > graceful_timeout`。

## 工程实现要点

### 环境隔离：一份镜像，三种环境

| 环境 | APP_ENV | 数据库 | 发布 | 数据 |
|---|---|---|---|---|
| 本地 | dev | 容器内 postgres | `uvicorn --reload` | 可随意重置 |
| 测试 | staging | 独立实例 | main 合并自动部署 | 脱敏副本 |
| 生产 | prod | 独立实例 + 备份 | 人工审批 + 灰度 | 真实数据 |

配置只在一处解析：`app/core/config.py` 用 Pydantic Settings 读环境变量，必填项缺失**启动即失败**；生产密钥不进 `.env` 文件，用 Docker secrets / 云 KMS / `*_FILE` 约定。

**学习写法 vs 生产写法**：初学者把 `DATABASE_URL` 写在 `config.py` 里，因为改起来最快；企业把配置全部外置按环境注入，因为同一镜像要能部署到任意环境，且密码写进 Git 等于永久泄露（改密码也无法从历史中删除）。

### CI/CD：Lint → Test → Build → 镜像 → 发布

```text
.github/workflows/ci.yml
  lint            ruff check . && ruff format --check . && mypy app
  test            services: postgres:16 + redis:7；alembic upgrade head
                  pytest -q --cov=app --cov-fail-under=70
  build-and-push  needs: [lint, test]；仅 main 分支；docker build -t $IMAGE:${{ github.sha }} . && docker push
  deploy          needs: build-and-push；environment: production（人工审批）
                  ssh deploy@<host> "cd /srv/dog/deploy && IMAGE_TAG=${{ github.sha }} \
                    docker compose up -d --no-deps api"
```

- **镜像 tag 必须用 commit SHA，禁用 `latest`**：回滚即换 tag，无需重新构建。
- Lint/Test 失败必须阻断 Build，否则门禁形同虚设；`main` 受保护，禁止直推。
- 迁移与代码解耦：**先做向后兼容迁移（只加列/加表）→ 再发新代码 → 最后清理旧列**（expand-contract）。绝不把"删列 + 改代码"放进同一次发布。

### 灰度与回滚

```nginx
# http 段按 5% 分流，逐级 5% → 25% → 50% → 100%，每级至少观察 15 分钟
split_clients "${remote_addr}${request_id}" $api_pool { 5% api_new; * api_old; }
# location 内改用 proxy_pass http://$api_pool;
```

观测门槛（任一不达标即回滚）：5xx 比例 > 1%；P95 延迟比旧版本上涨 > 50%；`/health` 连续 2 次失败；MQTT 在线设备数异常下降。回滚即切回旧 tag 并单独重起 api 容器：

```bash
cd /srv/dog/deploy && IMAGE_TAG=<上一个 commit SHA> docker compose up -d --no-deps api
docker compose logs --tail=200 api && curl -sS http://127.0.0.1/api/v1/health
```

前提：旧 tag 镜像仍在 registry，且本次发布没跑不可逆迁移；迁移不可逆时只能向前修复——这就是迁移要可逆且向后兼容的原因。

### 备份与恢复演练

```bash
#!/usr/bin/env bash
# deploy/scripts/backup_pg.sh —— systemd timer 每日 03:00 UTC 触发
set -euo pipefail     # 缺这行会让 pg_dump 失败后仍上传空文件，"看起来成功"
STAMP=$(date -u +%Y%m%dT%H%M%SZ); OUT=/srv/backup/pg/dog_${STAMP}.dump
docker compose exec -T postgres pg_dump -U dog -d dog -Fc -Z 6 > "$OUT"
sha256sum "$OUT" > "$OUT.sha256" && aws s3 cp "$OUT" "s3://<bucket>/pg/$(basename "$OUT")"
find /srv/backup/pg -name '*.dump' -mtime +3 -delete   # 本地只留 3 天，防磁盘写满
# 对象存储生命周期：日备 14 天 / 周备 8 周 / 月备 12 月
```

```bash
# 每月恢复演练（必须做）：恢复到临时库，绝不覆盖生产库
docker compose exec -T postgres createdb -U dog dog_restore_drill
docker compose exec -T postgres pg_restore -U dog -d dog_restore_drill --clean --if-exists < dog_<STAMP>.dump
docker compose exec -T postgres psql -U dog -d dog_restore_drill -c \
  "select (select count(*) from users) users, (select count(*) from devices) devices;"
docker compose exec -T postgres dropdb -U dog dog_restore_drill
```

记录 RTO（开始恢复到可查询的耗时）与 RPO（备份点距今），写进演练报告。单机 Compose 参考目标：RPO ≤ 24h（日备）/ ≤ 5min（开 WAL 归档），RTO ≤ 30min；达不到就升级策略（WAL 归档或流复制）。

### 监控与告警

```yaml
# prometheus/prometheus.yml
global: { scrape_interval: 15s, evaluation_interval: 15s }
rule_files: ["/etc/prometheus/alerts.yml"]
scrape_configs: [{ job_name: api, metrics_path: /metrics, static_configs: [{ targets: ["api:8000"] }] }]
```

| 告警 | 表达式要点 | for |
|---|---|---|
| ApiDown | `up{job="api"} == 0` | 1m |
| HighErrorRate | 5xx 占比 > 1%（`rate(...{status=~"5.."}[5m])`） | 5m |
| SlowP95 | `histogram_quantile(0.95, sum(rate(..._bucket[5m])) by (le)) > 1.0` | 10m |
| PgConnectionsHigh / DiskWillFill | 活跃连接 > 80% `max_connections`；`predict_linear(node_filesystem_avail_bytes{mountpoint="/"}[6h], 86400) < 0` | 5m / 30m |

Redis 内存（> 85%）、MQTT 在线设备数为 0、证书剩余 < 14 天也同样覆盖。Grafana 看板最小集：QPS、P50/P95/P99、错误率、各依赖健康、在线设备数、CPU/内存/磁盘。告警三条纪律：① 每条必须对应一个动作（重启/扩容/回滚/联系谁），无动作的删掉；② critical 走电话或企微，warning 走群消息；③ 必须有 `for` 持续时间，避免抖动刷屏。

### 日志集中化

- 应用输出**单行 JSON**（structlog），字段至少：`timestamp`、`level`、`service`、`trace_id`、`request_id`、`user_id`、`device_id`、`msg`；容器 `json-file` 驱动必须配 `max-size: 50m` + `max-file: 5`，否则日志会写满磁盘。
- 选型：单机量级用 Loki + Promtail（与 Grafana 同 UI，成本低）；多集群用 Fluent Bit/Filebeat → Elasticsearch/OpenSearch。
- **日志禁止出现**密码、Token、完整手机号、设备密钥，在日志中间件里做字段脱敏；排查入口永远是 trace_id —— Nginx `$request_id` 透传到应用、MQTT 回调、Celery 任务，一次检索得到完整调用链。

### 容量与成本意识

| 维度 | 观测指标 | 动作 |
|---|---|---|
| CPU / 内存 / 磁盘 | CPU P95 > 70%、内存 > 80% 限额、`/` 可用 < 20% | 先查泄漏（worker 重启频次）再扩副本或提限额；清日志备份、加盘、迁对象存储 |
| 数据库连接 | 活跃连接 > 80% `max_connections` | 调小应用连接池或上 PgBouncer |
| MQTT / 带宽 | 在线设备数、消息吞吐、图片视频出口流量 | Broker 集群化（单机上限待核实，查官方文档）、上 CDN |

先用 **1 台规格合理的机器 + 定期快照**跑通，不要一开始上 K8s；数据库不要与跑机器人的应用抢同一块盘；音视频图片放对象存储不进数据库。所有资源打标签（项目/环境/负责人），否则账单无法归因。

## 常见坑与验收标准

**常见坑**

1. 改完 `sshd_config` 直接断开当前会话、没验证密钥 → 锁死自己；`ufw enable` 前没放行 22 同理。
2. 把 PostgreSQL 5432、Redis 6379 用 `ports` 映射到 `0.0.0.0` → 未授权访问，被挖矿/勒索。必须用 `expose`。
3. 用 `latest` tag → 说不清线上跑的是什么，也无法精确回滚；迁移与代码同批发布且不可逆 → 回滚即数据不一致。
4. `stop_grace_period` 小于 `graceful_timeout` → 每次发布都在中途杀请求，表现为发布瞬间 502。
5. 没有日志轮转 → 磁盘写满 → 数据库只读、全站异常（"半夜全站挂掉"的常见真凶）；备份脚本缺 `set -euo pipefail` → dump 失败却上传空文件，"看起来成功"。
6. 只本地 `docker compose up` 验证过就发布，没在 staging 跑完整迁移；`.env.prod` 误提交 Git 必须**立即吊销并轮换全部密钥**，删文件不够。
7. 健康检查只看进程存活、不查依赖 → "进程在但业务全废"也通过检查，流量继续被送进来。

**验收标准（逐条自测，不是感觉）**

- [ ] `ssh -o PreferredAuthentications=password deploy@<IP>` 被拒绝、密钥登录成功；`ufw status verbose` 仅放行 22/80/443，有授权目标的扫描无其他开放端口。
- [ ] `docker compose ps` 中 api/postgres/redis 全为 `healthy`；`down && up -d` 后无人工干预自动恢复；公网 `/api/v1/health` 返回 200 而 `http://<IP>:8000` 不可达，`/metrics` 公网 403、Prometheus 内网抓取成功。
- [ ] 停掉 PostgreSQL 容器后 `/health` 在 10s 内返回非 200 且 `postgres` 字段为 `down`；恢复后 30s 内自动转 `up`。
- [ ] 故意写一处 lint 错误提 PR，流水线在 lint 阶段失败且未构建镜像；切到旧 tag 回滚后 2 分钟内恢复。
- [ ] 从最近 dump 恢复到临时库并记录实际 RTO、核对行数量级；人为制造 5xx 持续 5 分钟收到 `HighErrorRate` 告警；按真实 `trace_id` 在 Grafana 同时检索到 Nginx 访问日志与应用 JSON 日志。
- [ ] 能画出线上架构图并说明哪层限流、哪层做 TLS、高峰先撞哪个瓶颈、哪一步先告警。

## 学习路径

前置知识：Linux 权限与 `systemd`、Shell 与管道、HTTP/HTTPS 与 TLS 握手、TCP 端口与 DNS、进程与信号（`SIGTERM` vs `SIGKILL`）、Git 分支与 tag；缺这些会看不懂本文一半命令。

1. **单机跑通 + 安全加固**（1.5 周）：Compose 起 api/postgres/redis，能用 `docker compose logs` 定位启动失败，重启后自动恢复；密钥登录、ufw、最小权限用户、fail2ban 到位，端口扫描结果符合预期。
2. **反代与域名**（1 周）：Nginx 反代 + 真实证书 + WebSocket 打通，APP 能通过 HTTPS 与 WSS 连上后端；发布过程零 502。
3. **CI/CD 与数据安全**（2 周）：PR 触发 lint+test，main 自动打镜像、审批后发布；备份脚本 + 恢复演练 + expand-contract 迁移；测试失败能阻断流水线，产出含 RTO/RPO 的演练报告。
4. **可观测性与成本**（2 周）：结构化日志 + trace_id 贯通 + Prometheus 指标 + Grafana 看板 + 3 条有效告警；灰度、回滚演练、容量与账单复盘。能不问任何人、仅看板就判断故障在哪一层，并说出容量上限与最先崩的一层。

每完成一级，回到自己的项目验证真实链路一次：APP → Nginx → FastAPI → PostgreSQL/Redis → MQTT → 设备，确认新增这一层没把既有链路弄坏。
