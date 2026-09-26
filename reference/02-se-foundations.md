## 是什么与为什么

这一层决定后面所有东西的上限：语言决定你能表达什么，内存与进程模型决定性能问题出在哪，网络分层决定故障该在哪一层查，Linux 与 Git 决定你能不能进真实团队干活。

### 语言学习次序：Python → C → C++ → JavaScript/TypeScript

| 顺序 | 语言 | 先学它解决什么问题 | 学到什么算够 |
|---|---|---|---|
| 1 | Python 3.11/3.12 | 语法噪音最低，最快跑通"请求→业务→数据库→返回"完整链路，脚本能力立刻能用在服务器上 | 能写异步接口、能读第三方库源码、理解异常与类型标注 |
| 2 | C（C11/C17） | 建立内存、指针、编译链接、ABI 的硬直觉；设备 SDK、厂商示例、下位机代码大量是 C | 能解释栈与堆，能读懂指针与结构体，能用 gdb 定位段错误 |
| 3 | C++（C++17 起步） | 在 C 之上做资源管理（RAII）与性能；ROS 2 节点与运控代码主要是 C++ | 能读懂 `unique_ptr`/`shared_ptr` 的用途，能编译一个 ROS 2 包骨架 |
| 4 | JavaScript → TypeScript | 前端、构建工具、脚本；TS 的类型思维与 Pydantic/类型标注互通 | 理解事件循环与 Promise，能给一个模块加出正确的接口类型 |

顺序理由：先用 Python 建立"系统能跑"的正反馈，再用 C/C++ 补底层，最后用 TS 补前端与类型工程。排错时你面对的是运行时行为，所以不要跳过 JavaScript 直接上 TypeScript。

### 内存与进程/线程/协程

- 栈（stack）每线程独立，放局部变量与调用帧，有大小上限，递归过深即栈溢出；堆（heap）由程序员（C/C++）或运行时（Python/JS）管理。
- 三类内存事故都在 C/C++ 里：忘记释放是内存泄漏，释放后再用是悬空指针，越界写会破坏相邻对象。静态区放全局与 `static` 变量，代码段只读。
- 性能问题常常不是"算法差"而是内存访问模式差：缓存局部性、频繁分配、大对象拷贝。
- 进程（process）独立地址空间，隔离强、创建与切换贵，靠管道/套接字/共享内存通信；线程（thread）共享堆与文件描述符，通信便宜但必须加锁，锁用错就是死锁或数据竞争。
- CPython 有全局解释器锁（GIL, Global Interpreter Lock）：同一时刻只有一个线程执行字节码，所以 **CPU 密集用多进程，I/O 密集用线程或协程（coroutine）**。CPython 3.13 起提供实验性 free-threaded 构建，生产可用性 `待核实`（核实途径：CPython 官方 What's New 文档 + 你的部署镜像）。
- 协程（asyncio）在单线程事件循环上做协作式切换；在里面写同步阻塞调用（`requests`、`time.sleep`、同步数据库驱动）会卡住整个循环。

### 网络分层：TCP/UDP 与 HTTP/HTTPS

- 传输控制协议（TCP, Transmission Control Protocol）：面向连接、有序、可靠、有重传；代价是握手延迟与队头阻塞。HTTP、数据库、MQTT、控制命令都走它——**命令不能丢**。
- 用户数据报协议（UDP, User Datagram Protocol）：无连接、不保证到达与顺序、开销小延迟低；用于实时遥测、音视频、服务发现。丢一帧无所谓、延迟不可忍的场景选它。
- 超文本传输协议（HTTP, Hypertext Transfer Protocol）在 TCP 之上（HTTP/3 改跑 QUIC/UDP）；传输层安全（TLS, Transport Layer Security）夹在 HTTP 与 TCP 之间就成了 HTTPS。HTTPS = HTTP + TLS，**不是另一种协议**。
- 端口直觉：HTTP 80、HTTPS 443、PostgreSQL 5432、Redis 6379、MySQL 3306、MQTT 1883/8883（TLS）；本机开发常用 8000（uvicorn 默认约定）。端口号不是安全措施，绑 127.0.0.1 才是。
- 一次请求五段耗时：DNS 解析 → TCP 握手 → TLS 握手 → 首字节（TTFB） → 传输完毕。排查必须分段看，不要笼统说"网络慢"。

### Linux/Ubuntu 与 Shell

目标发行版取 Ubuntu 22.04 LTS 或 24.04 LTS。最小命令集：`ls/cd/cp/mv/rm`、`cat/less/tail -f`、`grep`、`find`、`ps/htop`、`kill`、`chmod/chown`、`systemctl`、`journalctl -u`、`ip addr`/`ip route`、`ss -tunlp`、`ping`、`curl`、`tar`、`scp/rsync`、`apt`，以及管道与重定向（`|`、`>`、`2>&1`）和退出码 `$?`。Shell 基本功好的标志：排障时给的是一串**可复现命令**，而不是"你重启试试"。

### Git、包管理与虚拟环境

- Git：工作区 → 暂存区 → 本地仓库 → 远程仓库，四个位置对应四个你随时要能说清的状态。
- 包管理器（package manager）：Python 用 pip/uv，Node 用 npm/pnpm，C++ 用 CMake + vcpkg/Conan，系统层用 apt；它解决的是"依赖的依赖"这棵树的版本解析。
- 依赖锁文件（lock file）是团队一致性的根：`requirements.lock.txt`、`pnpm-lock.yaml`、`poetry.lock` 必须提交；`pyproject.toml`/`package.json` 只写约束，锁文件才写"实际装了什么"。
- 虚拟环境（virtual environment）：每项目独立解释器与包目录，避免 A 项目污染 B 项目。学习期 `python -m venv .venv` 足够；团队期看 `pyproject.toml` + `uv`/`poetry`（能力以官方文档为准）。

### 调试工具链：三层观测

| 层 | 工具 | 看什么 |
|---|---|---|
| 进程内 | pdb / `breakpoint()`、gdb/lldb、`python -X faulthandler` | 变量真实值、调用栈、崩溃点 |
| 进程外 | `strace`、`lsof -i :8000`、`py-spy`、`ps -o` | 系统调用、文件与端口占用、卡在哪个函数 |
| 网络上 | `curl -w`、`tcpdump`/`tshark`、Wireshark、浏览器 DevTools | 请求发没发出去、报文长什么样、TLS 到哪一步断 |

## 最小可运行示例

### 1. 虚拟环境与可复现依赖

```bash
# Ubuntu Bash（Windows PowerShell：python -m venv .venv 后 .\.venv\Scripts\Activate.ps1）
python3 --version                          # 确认 3.11+ / 3.12+
python3 -m venv .venv && source .venv/bin/activate
python -m pip install -U pip && pip install fastapi "uvicorn[standard]"
pip freeze > requirements.lock.txt         # 不凭记忆写版本号，以实际装到的为准
python -c "import sys; print(sys.prefix)"  # 路径必须在 .venv 内，否则没激活成功
```

### 2. 内存三段与泄漏（Ubuntu Bash）

```c
/* mem_demo.c —— gcc -Wall -Wextra -g -O0 mem_demo.c -o mem_demo */
#include <stdio.h>
#include <stdlib.h>
int g = 1;                                  /* 静态区 */
int main(void) {
    int local = 2;                          /* 栈 */
    int *heap = malloc(sizeof(int));        /* 堆 */
    if (!heap) return 1;                    /* 永远检查分配失败 */
    *heap = 3;
    printf("global=%p local=%p heap=%p\n", (void *)&g, (void *)&local, (void *)heap);
    free(heap);                             /* 注释掉这行，valgrind 会报 definitely lost */
    return 0;
}
```

```bash
# Ubuntu Bash（先 sudo apt install valgrind）
gcc -Wall -Wextra -g -O0 mem_demo.c -o mem_demo && ./mem_demo
valgrind --leak-check=full ./mem_demo
gdb -q ./mem_demo -ex run -ex bt            # 崩溃时直接拿调用栈
```

### 3. GIL：线程 vs 进程（Python 3.11+）

```python
# proc_thread.py —— 运行：python proc_thread.py
import multiprocessing as mp, threading, time
def burn(n: int) -> None:
    x = 0
    for i in range(n):
        x += i * i

if __name__ == "__main__":
    N = 5_000_000
    s = time.perf_counter(); burn(N); burn(N)
    print(f"串行 {time.perf_counter() - s:.2f}s")
    ts = [threading.Thread(target=burn, args=(N,)) for _ in range(2)]
    s = time.perf_counter(); [t.start() for t in ts]; [t.join() for t in ts]
    print(f"线程 {time.perf_counter() - s:.2f}s")   # 受 GIL 限制，通常不比串行快
    ps = [mp.Process(target=burn, args=(N,)) for _ in range(2)]
    s = time.perf_counter(); [p.start() for p in ps]; [p.join() for p in ps]
    print(f"进程 {time.perf_counter() - s:.2f}s")   # 多核并行，应明显快于串行
```

### 4. 分层测网络与抓包

```bash
# Ubuntu Bash
ss -tunlp                                  # 监听端口 + 归属进程 + TCP/UDP
curl -sS -o /dev/null -w 'dns=%{time_namelookup}s tcp=%{time_connect}s tls=%{time_appconnect}s ttfb=%{time_starttransfer}s total=%{time_total}s code=%{http_code}\n' https://example.com
curl -v https://example.com 2>&1 | grep -Ei 'SSL|TLS|subject|issuer|HTTP/'
sudo tcpdump -i any -nn -s0 -w /tmp/cap.pcap 'tcp port 8000'   # -i any 仅 Linux 支持
tshark -r /tmp/cap.pcap -Y 'http.request' -T fields -e ip.src -e http.host -e http.request.uri
# Windows PowerShell: Test-NetConnection example.com -Port 443
#                    Get-NetTCPConnection -LocalPort 8000 -ErrorAction SilentlyContinue
```

HTTPS 抓到的只有 TLS 密文。合法途径：① 看自己的服务端日志；② 用浏览器 DevTools 或 `SSLKEYLOGFILE` 会话密钥解密**自己的**流量；③ 抓本机明文口。不要抓别人的流量。

### 5. Git 最小协作流（Git ≥ 2.28）

```bash
git init -b main
git config user.name "你的名字" && git config user.email "you@example.com"
git add -A && git commit -m "chore: 初始化项目骨架"
git switch -c feat/device-binding           # 一个功能一个分支
git add -A && git commit -m "feat(device): 新增设备绑定接口"
git push -u origin feat/device-binding      # 然后开 Pull Request 等 Code Review
git switch main && git pull --ff-only       # 合并后同步主干
```

## 工程实现要点

### 练习仓库骨架与命名

```text
se-foundations/
├── .gitignore      # 必须含 .venv/ __pycache__/ .env node_modules/ *.pcap
├── .env.example    # 只放键名与示例值，真值进 .env（永不提交）；README.md 写目标/命令/预期输出
├── pyproject.toml + requirements.lock.txt
├── c/ cpp/ ts/     # 各自的 Makefile / CMakeLists.txt / package.json
├── scripts/        # 可复现的排查脚本，如 net_probe.sh
└── notes/ triage/  # 练习结论；triage/YYYY-MM-DD-主题.md：现象→原因→验证→修复
```

命名：目录小写连字符；Python 模块 `snake_case`；类型 `PascalCase`；常量 `UPPER_SNAKE`；分支用 `feat/`、`fix/`、`chore/`；提交信息用 Conventional Commits（`feat(scope): 描述`）。

### 默认参数与依据（学习期就用生产值）

| 参数 | 默认值 | 依据 |
|---|---|---|
| 外部 HTTP 连接 / 读取超时 | 3s / 5s | 正常握手远低于 1s，超过 3s 即异常；读取给对端留余量，需更久就单独放宽并注释 |
| 重试次数与退避 | 最多 3 次，0.5s/1s/2s + ±20% 抖动 | 再多是放大故障；指数退避避免打爆对端，抖动避免重试风暴同步 |
| 数据库连接池 | `pool_size=5`、`max_overflow=10`、`pool_pre_ping=True`、`pool_recycle=1800` | 池大小 ≈ 单进程并发量；`pre_ping` 防连接被中间件掐断；`recycle` 早于常见空闲超时 |
| Nginx 限流（起始值） | `rate=10r/s`、`burst=20` | 先观察真实 QPS 再调，宁先松后紧，避免误杀正常用户 |

不确定的数值（数据库默认最大连接数、Broker 默认限流等）不许凭记忆写：标 `待核实`，核实途径为官方文档、`SHOW VARIABLES`、服务端配置文件或压测实测。

### 学习写法 vs 生产写法（三处最典型）

1. **依赖安装**：① 初学者全局 `pip install`，只想快点看到结果。② 企业用虚拟环境 + 锁文件 + CI 里 `--frozen-lockfile`。③ 原因：全局安装不可复现，"我这儿能跑"会让同事与 CI 直接失败。
2. **调试输出**：① 初学者用 `print`，零配置。② 企业用结构化日志（structured logging）+ `trace_id`、统一异常处理，生产用 INFO 级且响应不含堆栈。③ 原因：线上不能 attach 调试器，日志没有上下文等于没有日志。
3. **密钥与配置**：① 初学者把地址与 Token 写进代码，省事。② 企业用环境变量/密钥管理，代码里只有键名，`.env` 进 `.gitignore`。③ 原因：仓库会被克隆与 fork，写进代码的密钥等于已泄露，轮换成本极高。

### 只读验证与回滚（涉及删除或生产写操作时强制）

动手前先只读预演：`git clean -nd`（列出将删文件而不删）、`rsync --dry-run`、用 `SELECT` 代替 `UPDATE`、把数据复制到测试库。回滚方式必须**在动手前**写下（备份路径、恢复命令、回滚时间点）。涉及机器人运动：先仿真、先只读读状态，再按 `08-locomotion-safety.md` 的 G0→G1→…→G5 门禁逐级放行，未过闸不得上真机。

## 常见坑与验收标准

| 常见坑 | 现象 | 正确做法 |
|---|---|---|
| 包装到全局环境 | 换项目就 ImportError 或版本冲突 | 每项目 `.venv`，`sys.prefix` 必须指向项目内 |
| 提交敏感与大文件 | 仓库出现 `.env`、`node_modules`、`.pcap` | 先写 `.gitignore` 再 `git add`；已提交的用 `git filter-repo` 清历史并立即轮换密钥 |
| CRLF/LF 混用 | Linux 上报 `bad interpreter: ^M` | 编辑器统一 LF，仓库加 `.gitattributes` |
| `localhost` 与容器网络混淆 | 容器里连 127.0.0.1 连不上数据库 | 容器内用服务名；先 `ip addr`/`getent hosts` 确认解析 |
| "ping 通就是通的" | ICMP 通但服务连不上 | ICMP 与 TCP 是两件事，用 `ss -tunlp`、`nc -vz host port`、`curl -v` 验证端口 |
| 忽视证书校验 | 代码里出现 `verify=False` | 修证书链或加信任根，禁止关校验上生产 |
| 协程里写阻塞调用 | 并发上不去、接口整体变慢 | I/O 用异步驱动，CPU 密集丢给进程池 |
| 时间与时区 | 日志时间对不上、跨时区算错 | 存储与传输统一 UTC，展示层转本地时区 |
| 抓包看不到业务内容 | pcap 全是 TLS 密文 | 认清加密边界：用服务端日志或会话密钥解密自己的流量，不要抓别人的流量 |

### 练习清单：从零到能独立排查问题（每条含验证方式）

| # | 练习 | 验证方式（做到什么算过） |
|---|---|---|
| 1 | 建 `.venv`，装 3 个库，导出锁文件，删环境后重建 | 重建后 `pip install -r requirements.lock.txt` 成功，`pip check` 无冲突 |
| 2 | 用 C 写一个会段错误的程序，用 gdb 定位 | `gdb -ex run -ex bt` 能说出崩溃在哪个函数、哪个变量 |
| 3 | 故意泄漏内存并用 valgrind 找出 | valgrind 报 `definitely lost` 且能指出对应 `malloc` 行 |
| 4 | 跑通 GIL 对比脚本 | 记录三种模式耗时数据，能解释线程为何不快 |
| 5 | 用 `ss -tunlp` 找出某端口属于哪个进程 | 端口号、进程名、PID 三样都对；再 `kill` 掉它并复验 |
| 6 | 用 `curl -w` 把 DNS/TCP/TLS/TTFB 分段测出 | 能指出哪一段异常，并说出该段该用哪个工具 |
| 7 | 本机起 HTTP 服务，`tcpdump` 抓包并用 `tshark` 过滤 | 在抓到的请求里读出方法、Host、路径 |
| 8 | 对 HTTPS 站点做 `curl -v`，读出证书颁发者与 TLS 版本 | 能说明 HTTPS 在 HTTP 之外多做了哪些步骤 |
| 9 | 制造一次 4xx 与一次 5xx（不存在的路径 / 服务未启动） | 能区分"客户端错"与"服务端错"，并给出各自下一步命令 |
| 10 | 用 `tcpdump` 观察 UDP 丢包 | 能解释为什么 UDP 应用必须自己实现超时与序号 |
| 11 | 在 Git 上完整走分支→提交→推送→PR→合并 | 提交历史清晰（一个功能一个提交），能讲清 merge 与 rebase 的差别 |
| 12 | 制造一次合并冲突并解决 | 冲突两方都理解，解决后测试仍通过 |
| 13 | 用 `git clean -nd`、`rsync --dry-run` 做删除前预演 | 先看到将删清单再执行，能说出回滚方式 |
| 14 | 用 `ulimit`/`/proc` 找出一个进程的内存/句柄/CPU 异常 | 能指出是内存涨、句柄涨还是 CPU 涨，并给出对应工具 |
| 15 | 用 `python -X faulthandler` + pdb 定位"卡住不返回"的脚本 | 能说清卡在哪个调用栈，并判断是等 I/O 还是死锁 |
| 16 | 给一个真实报错写完整七步排查记录到 `triage/` | 记录含现象→原因→验证命令→结果判断→修复→复盘，别人照做能复现；涉及删除或机器人运动的练习先只读预演/仿真 |

## 学习路径

- **前置与第 1 阶段（Python + Linux + Git，约 3~4 周）**：无前置，只需一台能开 WSL2 或虚拟机的机器（Ubuntu 22.04/24.04 LTS）+ 一个 GitHub 账号；练习 1、11、12、14。里程碑：能用命令行完成"建环境→跑服务→看日志→定位一个 404"，并留下一份干净的提交历史。
- **第 2 阶段（C 与内存，约 3 周）**：练习 2、3。里程碑：看到段错误不再"猜"，而是直接用调用栈与 valgrind 输出定位。这一阶段是后面读懂 SDK 与运控代码的地基。
- **第 3 阶段（网络与观测，约 3 周）**：练习 5~10、15。里程碑：任何一个"连不上/很慢"的问题，你能按 DNS→TCP→TLS→应用四段给出少量命令并逐段判断。
- **第 4 阶段（C++ 与 TypeScript 衔接）**：C++ 学到能编译读懂一个 ROS 2 包；TS 学到能读懂前端接口调用。里程碑：能独立把"接口连通"这件事从浏览器一路排查到后端日志。
- **每次练习的固定收尾三行**：今天掌握了什么 / 还差什么 / 下一步做什么，写进 `notes/` 与学习账本。
