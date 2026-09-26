# 前端与网站（HTML/CSS、TypeScript、Vue 3 与前端工程化）

## 是什么与为什么

前端是**把后端状态翻译成用户能操作、能信任的界面**的那一层：页面负责呈现与交互，状态存放业务真相的副本，请求层负责与后端通信，契约负责让两侧类型对齐。链路：
`用户操作 → 组件事件 → store action → api 请求层 → 后端 /api/v1 → 归一化结果 → store 状态 → 视图重渲染`
三条不可违背的分工原则：
- **界面只读状态，不自己造真相**：组件收到的是 store 或 props 里的数据；"到底有没有控制成功"以后端 ACK 与状态回报为准，前端按钮置灰只是防误触，不是安全边界。
- **数据单向流动**：props 向下、emits 向上；子组件不改父组件传进来的对象，需要改就发事件。这条一旦破例，排查"界面为什么变了"就没有入口。
- **契约优先于手感**：接口字段、错误码、事件名从 OpenAPI 与后端约定生成，而不是对着浏览器手抄一遍——手抄的字段在字段改名那天不会报错，只会在线上白屏。

选型上：**Vue 3 作为主实现**（Composition API + Pinia + Vue Router + Vite），React 只做关键差异对照（见后文对照表），避免维护两套等价示例。

## 最小可运行示例

未标注处均为 **Ubuntu Bash / macOS Bash**；Windows PowerShell 的差异在行内标注。

目录结构（`src/` 下按"职责"分目录，不按"文件类型堆放"）：
```text
web/
  vite.config.ts  tsconfig.json  eslint.config.js  .prettierrc
  .env.development  .env.staging  .env.production  .env.example
  index.html                       # 唯一入口 HTML，Vite 以它为模板
  src/
    main.ts                        # 只做装配：建应用、装插件、挂载
    App.vue                        # 根组件：布局骨架 + <RouterView>
    views/                         # 路由级页面 DeviceListView.vue OrderDetailView.vue
    components/                    # 可复用组件 DeviceCard.vue CommandButton.vue
    stores/  api/                  # Pinia device.ts auth.ts ｜ client.ts devices.ts schema.d.ts（生成）
    router/  composables/          # index.ts（路由表）guards.ts ｜ useWebSocket.ts usePagination.ts
    utils/  types/                 # format.ts storage.ts ｜ 手写领域类型（生成类型之外的补充）
  tests/unit/  tests/e2e/
```

命名约定：组件文件 `PascalCase.vue`（模板里当标签用，必须多词避免与原生标签冲突）；其余 `.ts` 用 `camelCase`；目录用 `kebab-case` 或全小写；store 文件名与 `defineStore` 的 id 一致。

```html
<!-- src/components/DeviceCard.vue：语义化 + 只读 props + 事件上抛 -->
<template>
  <article class="card" :class="{ 'card--offline': !device.online }">
    <header class="card__head">
      <h2 class="card__title">{{ device.name }}</h2>
      <span class="badge" role="status">{{ device.online ? '在线' : '离线' }}</span>
    </header>
    <dl class="card__meta"><dt>最近上报</dt><dd>{{ lastSeenText }}</dd></dl>
    <button type="button" class="btn" :disabled="busy || !device.online" @click="emit('control', { id: device.id, command: 'stop' })">
      {{ busy ? '下发中…' : '停止' }}
    </button>
  </article>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue'
import type { Device } from '@/types/device'

const props = defineProps<{ device: Device; busy?: boolean }>()
const emit = defineEmits<{ control: [payload: { id: string; command: string }] }>()
const lastSeenText = computed(() => props.device.lastSeenAt ? new Date(props.device.lastSeenAt).toLocaleString() : '无数据')
const busy = ref(props.busy ?? false)
</script>

<style scoped>
.card { padding: 16px; border: 1px solid var(--color-border); border-radius: var(--radius-md); }
.card__head { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
.card--offline { opacity: .6; }          /* 离线态只用透明度不够，模板里同时给了文字 */
@media (max-width: 480px) { .card { padding: 12px; } }   /* 断点值依据见"响应式"一节 */
</style>
```

```ts
// src/api/client.ts：一个 axios 实例 + 两类拦截器，错误在这里归一，组件不许认识 axios
import axios, { AxiosError, type AxiosRequestConfig } from 'axios'
import { useAuthStore } from '@/stores/auth'

export interface ApiError { code: number; message: string; traceId?: string; httpStatus?: number }
const http = axios.create({
  baseURL: import.meta.env.VITE_API_BASE_URL,   // 构建期注入，见"环境变量与密钥边界"
  timeout: 10_000,                              // 普通业务读接口 10s；控制类指令等 ACK 5s，见后端契约
})

http.interceptors.request.use((cfg) => {
  const token = useAuthStore().accessToken
  if (token) cfg.headers.Authorization = `Bearer ${token}`
  // 与后端 trace_id 闭环；crypto.randomUUID 的浏览器支持按项目目标浏览器核实，不可用时降级为时间戳+随机数
  if (cfg.data !== undefined && !cfg.headers['X-Request-ID']) cfg.headers['X-Request-ID'] = crypto.randomUUID()
  return cfg
})

let refreshing: Promise<string> | null = null      // 并发 401 只发一次刷新，见后端契约一节

http.interceptors.response.use(
  (res) => res.data,                              // 后端统一 { code, message, data, trace_id }，这里剥一层
  async (err: AxiosError<{ code: number; message: string; trace_id?: string }>) => {
    const cfg = err.config as AxiosRequestConfig & { _retried?: boolean }
    if (err.response?.status === 401 && !cfg._retried) {          // 只重试一次，防止死循环
      cfg._retried = true
      refreshing ??= useAuthStore().refresh().finally(() => { refreshing = null })
      try { await refreshing; return http(cfg) } catch { useAuthStore().logout(); throw err }
    }
    const body = err.response?.data                                  // 错误归一：组件只认识 ApiError
    const apiError: ApiError = {                                     // -1 = 网络层失败，没有业务码
      code: body?.code ?? -1,
      message: body?.message ?? (err.code === 'ECONNABORTED' ? '请求超时' : '网络异常，请稍后重试'),
      traceId: body?.trace_id, httpStatus: err.response?.status,
    }
    return Promise.reject(apiError)
  },
)

export default http
```

```ts
// src/stores/device.ts：Pinia setup 写法；store 只放跨组件共享且需要存活的状态
import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import http, { type ApiError } from '@/api/client'
import type { Device } from '@/types/device'

export const useDeviceStore = defineStore('device', () => {
  const items = ref<Device[]>([])
  const page = ref(1); const pageSize = ref(20); const total = ref(0)   // 与后端 ?page&page_size 对齐，上限 100
  const loading = ref(false); const error = ref<ApiError | null>(null)
  const onlineCount = computed(() => items.value.filter((d) => d.online).length)

  async function fetchPage(next = page.value) {
    loading.value = true; error.value = null
    try {
      const res = await http.get<never, { items: Device[]; total: number }>('/devices', { params: { page: next, page_size: pageSize.value } })
      items.value = res.items; total.value = res.total; page.value = next
    } catch (e) { error.value = e as ApiError } finally { loading.value = false }
  }

  // 乐观更新：先改本地，失败必须回滚，否则界面显示的状态比真相更"新"
  async function toggleOnline(id: string, online: boolean) {
    const target = items.value.find((d) => d.id === id); if (!target) return
    const prev = target.online; target.online = online
    try { await http.patch(`/devices/${id}`, { online }) } catch (e) { target.online = prev; error.value = e as ApiError; throw e }
  }

  return { items, page, pageSize, total, loading, error, onlineCount, fetchPage, toggleOnline }
})
```

```ts
// src/router/index.ts + src/router/guards.ts：路由表与鉴权守卫分开，守卫里不写业务
import { createRouter, createWebHistory } from 'vue-router'
import { useAuthStore } from '@/stores/auth'

export const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),   // 部署在子路径时必须与 Nginx location 一致
  routes: [
    { path: '/login', name: 'login', component: () => import('@/views/LoginView.vue'), meta: { public: true } },
    { path: '/devices', name: 'devices', component: () => import('@/views/DeviceListView.vue') },
    { path: '/devices/:id', name: 'device-detail', component: () => import('@/views/DeviceDetailView.vue'), props: true },
  ],
})

router.beforeEach((to) => {
  if (to.meta.public || useAuthStore().accessToken) return true
  return { name: 'login', query: { redirect: to.fullPath } }   // 登录后回跳原地址
})
```

启动与构建（Bash）：`npm create vite@latest` 选 Vue + TypeScript 模板 → `npm install` → `npm run dev`（默认 5173 端口）→ `npm run build` → `npm run preview`。Windows PowerShell 相同命令；若用 pnpm/yarn 只改包管理器前缀。`package.json` 里加 `"typecheck": "vue-tsc --noEmit"`，CI 里与 `build` 一起跑。

## 工程实现要点

### HTML/CSS 与布局
- **语义化标签与盒模型**：`header/nav/main/section/article/footer/button/label` 决定屏幕阅读器与搜索引擎如何理解页面，`div` 只用在没有任何语义的容器上；表单控件必须配 `<label for>`，否则点击文字不聚焦、读屏读不出字段名。全局 `*, *::before, *::after { box-sizing: border-box }` 把宽高定义为"含内边距与边框"，避免加 padding 就撑破布局；外边距折叠只发生在块级纵向相邻元素之间，用 Flex/Grid 容器或 `gap` 绕开。
- **Flex 与 Grid 的选用**：一维排列（导航条、按钮组、卡片内部对齐）用 Flex；二维对齐（整页布局、卡片网格、表格式面板）用 Grid。判断句：**只需要"排在一行或一列"就 Flex，需要"行列同时受控"就 Grid**。两者都不用时，垂直居中与等高列要靠 hack。
- **响应式**：媒体查询按内容断点而不是设备型号（常见起点 480 / 768 / 1024 / 1280 px，依据是手机竖屏 / 平板竖屏 / 小笔记本 / 桌面）；组件级自适应用容器查询 `@container`，让组件按**自身可用宽度**换布局，同一组件放进侧栏与主区都能正确显示。容器查询与 `:has()` 的浏览器支持需按项目目标浏览器核实，降级方案是媒体查询 + `ResizeObserver`。
- **移动端适配**：`<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">`；高度用 `100dvh` 而不是 `100vh`（移动端浏览器工具栏伸缩会让 `100vh` 溢出）；刘海屏用 `env(safe-area-inset-top)` 等安全区变量配合 `viewport-fit=cover`；**可点击目标最小 44×44 CSS px**（WCAG 2.2 目标尺寸 24px 为最低线，44px 来自移动端人机指南的通用实践，取值依据需按项目采用的规范版本核实）；表单输入框 `font-size` 不小于 16px，否则移动端浏览器聚焦时会自动放大页面。
- **CSS 变量与主题**：设计令牌集中在 `:root`（`--color-bg / --color-text / --color-primary / --radius-md / --space-2`），组件只引用变量不写裸色值；深色主题在 `[data-theme="dark"]` 下覆盖同名变量即可整体切换；`prefers-color-scheme` 作为默认值，用户手动切换写进 `localStorage` 并用内联脚本在首屏前应用，避免主题闪烁。

### JavaScript 与 TypeScript 工程
- **事件循环**：宏任务（`setTimeout`、I/O 回调）与微任务（Promise 回调、`queueMicrotask`）分队列；一轮宏任务结束后清空全部微任务。因此 `await` 之后的状态更新会先于下一个 `setTimeout` 执行，"用 `setTimeout(fn, 0)` 等 DOM 更新"不可靠，等 DOM 应该用框架提供的时机（Vue 的 `nextTick`）。
- **Promise、async/await 与模块化**：`Promise.all` 是快速失败（一个 rejection 即整体 rejection），需要"全部结果都要拿到"时用 `Promise.allSettled`；循环里 `await` 是串行，独立请求要用 `Promise.all` 并发，但**必须给并发数上限**（默认建议 5–6，依据是浏览器对同域 HTTP/1.1 连接数的常见限制，HTTP/2 下由流控决定，具体值按实际压测调整）。`import`/`export` 是静态分析的基础，动态 `import()` 才产生代码分割；不要在请求层或 store 之间用循环依赖，会得到"初始化时是 undefined"的报错。
- **`strict` 模式与类型设计**：`tsconfig.json` 打开 `"strict": true`，并追加 `noUncheckedIndexedAccess`（下标访问结果含 `undefined`）、`noImplicitOverride`、`exactOptionalPropertyTypes`（可选属性不等于 `undefined`）——这些开关会先制造一堆报错，那正是它们在替你找未来的运行时错误。类型上用**联合类型**表达"有限取值"（`type CmdResult = 'OK' | 'OFFLINE' | 'TIMEOUT' | 'COMMAND_FAILED'`，与后端 `CommandResult` 枚举一一对应，`switch` 缺分支会被穷尽性检查抓住）；用**泛型**表达"容器与元素解耦"（`interface Page<T> { items: T[]; total: number }`）而非复制多份接口；`unknown` 表示"还不知道，用前必须收窄"，`any` 表示"放弃检查并向调用方扩散"，请求层与 `catch` 分支只允许 `unknown`，用类型守卫（`function isApiError(e: unknown): e is ApiError`）收窄。
- **与后端 Pydantic/OpenAPI 类型的对应关系**：`openapi-typescript` 从 `/openapi.json` 生成 `src/api/schema.d.ts`（生成物进版本库、在 CI 校验是否最新），业务代码在其上取类型别名，后端改字段后 `vue-tsc --noEmit` 直接报错。三处映射必须留意：`datetime` 在 JSON 里是 ISO 8601 **字符串**而不是 `Date`，转换只发生在展示层；`int` 在 JS 里统一是双精度浮点，超过 2^53 的整数字段（如雪花 ID）必须改为字符串传输，否则精度丢失；`Optional[X]` 同时覆盖"字段缺失"与"值为 null"，前端类型应写 `field?: T | null` 并按后端实际是否 `exclude_none` 核实。

### Vue 3（Composition API）
- `<script setup>` + `defineProps` / `defineEmits` 是**编译期契约**：props 只读、emits 有类型，父组件用错字段名立刻报错。props 用于"父传子的输入"，emits 用于"子的变更请求"，`v-model` 只是 `modelValue` + `update:modelValue` 的语法糖（默认事件名与 `modelValue` 属性名以当前 Vue 版本文档为准；`defineModel` 宏在较新版本可用，是否启用按项目锁定的版本核实）。
- `ref` 用于基本类型与需要整体替换的对象；`reactive` 用于结构稳定的对象。不要解构 `reactive` 对象（会丢响应性），需要解构用 `toRefs`。`computed` 只做纯计算，不放副作用与请求。`watch` 与 `watchEffect` 的**副作用必须清理**：监听器里发起请求或注册监听时用 `onCleanup` 取消上一次（`AbortController` 是最通用手段），否则快速切换筛选条件会出现"后发先至"、界面显示旧条件的数据；`onUnmounted` 里注销全局监听（`window` 事件、定时器、WebSocket 订阅），组件卸载后仍在跑的定时器是内存泄漏的常见来源。
- 组件拆分判据：出现"同一段模板 + 同一段逻辑"第二遍就该抽；单文件超过约 300 行、或 props 超过 7 个，通常说明职责没切干净。展示组件（吃 props 吐事件、不碰 store）与容器组件（连 store 与路由）分开写，展示组件才好测。插槽用于"父组件决定子组件内部结构"（具名插槽 + 作用域插槽把子组件数据回传给父模板），不要把插槽当 props 传数据用。**Pinia 的边界**：进 store 的条件是"跨路由或跨多个不相关组件共享"且"需要在组件卸载后继续存在"（会话、设备列表缓存、筛选条件、未读计数）；只服务当前页面的临时状态（弹窗开关、输入框草稿、当前 tab）留在组件 `ref` 里。**服务端数据不要无脑全塞 store**：能用路由参数或请求缓存表达的就别复制一份，复制越多，越容易出现两处真相不一致。

### React 关键差异对照
同为组件化 + 单向数据流，差异集中在"状态怎么变、什么时候重渲染、生态往哪走"：

| 维度 | Vue 3 | React（函数组件 + Hooks） |
|---|---|---|
| 响应式机制 | 基于 Proxy 的细粒度依赖追踪：改哪个 `ref` 就只重渲染用到它的组件 | 状态更新触发组件函数重跑，靠 `memo` / `useMemo` / `useCallback` 手动抑制多余渲染 |
| 状态原语 | `ref` / `reactive`，可直接赋值 `count.value++` | `useState` 返回 `[值, setter]`，**不可变更新**（数组要 `[...arr, x]`） |
| 副作用 | `watch` / `watchEffect` 显式声明依赖或自动收集，有 `onCleanup` | `useEffect` 依赖数组决定执行时机，漏写依赖导致闭包读到旧值（stale closure） |
| 逻辑复用 | composables：普通函数，返回响应式数据 | 自定义 Hook：函数 + 依赖数组，规则更严（不可条件调用） |
| 模板/渲染 | SFC 模板 + 指令（`v-if` / `v-for` / `v-model`），编译期优化 | JSX，全用 JS 表达式（`{cond ? <A/> : <B/>}`、`map`） |
| 表单与路由 | `v-model` 双向绑定；Pinia 为官方推荐；Vue Router 官方维护，守卫以 `beforeEach` 返回值为核心 | 受控组件手写 `value` + `onChange`；状态管理无唯一答案（Context / Redux 系 / Zustand 并列）；React Router 社区主流，鉴权常在布局组件里做 |
| 类型与生态 | `vue-tsc` 检查模板类型（偶有偏移）；模板 + 指令对新手更友好、约定多；中文社区密集，企业后台管理类项目占比高 | TSX 与 TS 同源、类型报错更直接，但需先理解闭包、不可变与渲染时机；全球生态最大，跨端（React Native）与复杂交互类项目选择更多 |

取舍结论：**同等规模的业务系统，两者都能做**。选型的真实变量是"团队已有经验 + 是否需要 React Native 这类同语言跨端能力 + 第三方库需求"，不是性能。别为了"更流行"在项目中途换框架。
### 前端工程化与部署
- **Vite** 的定位：开发期用原生 ESM + 依赖预构建，启动与热更新只处理改动的模块；构建期用 Rollup 打产物，文件名带内容 hash。默认无需额外配置即可用 TS 与 `.vue`；需要配置的多是路径别名（`@` → `src`）、代理（开发期把 `/api` 转发到本地后端，避免 CORS）、`build.sourcemap` 与分包策略。
- **环境变量与密钥边界**：Vite 只把 **`VITE_` 前缀**的变量注入客户端代码，注入发生在**构建期**并把值**明文编译进产物**——打开任意浏览器都能读到。因此前端环境变量只能放"公开配置"（API 基地址、埋点 key、地图公钥），**任何密钥、数据库连接、第三方服务私钥一律不得放前端**；这类值只能留在后端，前端通过自己的接口间接使用。`.env.*` 中除 `.env.example` 外都不入库，`.gitignore` 必须覆盖。
- **ESLint / Prettier 分工**：ESLint 管"可能出错与风格之外的问题"（未使用变量、错误的响应式用法、缺失的 key、不安全的 `any`），Prettier 管"纯格式"，两者交集交给 `eslint-config-prettier` 关闭冲突规则。配置进版本库并在 CI 里跑 `lint`（ESLint 新版的 flat config 文件名与写法按所用版本核实），本地用编辑器保存时格式化 + Git 提交前钩子（husky + lint-staged 类方案）保证增量文件始终合规。
- **Nginx 部署（前端路由的关键一行）**：SPA 是单页应用，`/devices/123` 这类路径在服务器上**没有对应文件**，直接访问会 404。必须把未命中的请求回落到 `index.html` 交给前端路由处理。

```nginx
# /etc/nginx/conf.d/web.conf（片段）：静态站点 + SPA 回落 + 缓存策略
server {
    listen 443 ssl;
    server_name example.internal;
    root /srv/web/current;                 # 指向当前发布目录（软链切换实现回滚）
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;  # 命中文件就返回文件，否则回落 index.html
    }
    location /assets/ {                     # 构建产物目录，文件名带 hash，可长期强缓存
        expires 1y;
        add_header Cache-Control "public, max-age=31536000, immutable";
    }
    location = /index.html {                # 入口 HTML 绝不缓存，否则发布后用户仍拿旧页面
        add_header Cache-Control "no-cache";
    }
    location /api/ { proxy_pass http://127.0.0.1:8000; proxy_set_header X-Request-ID $request_id; }
}
```

  同理：`index.html` 短缓存或不缓存、带 hash 的静态资源长缓存、`gzip`/`brotli` 压缩、`try_files` 放行真实存在的文件（否则图片与 `robots.txt` 也会被回落成 HTML）。**改配置后先 `nginx -t` 再 reload**。
- **多环境发布**：约定三套模式 `development / staging / production`，各自一份 `.env.<mode>`（Vite 按 `--mode` 选择），命令统一为 `npm run build -- --mode staging`。同一份代码构建出三个产物目录，发布时只切软链接（`releases/<时间戳>` + `current` 软链），回滚即把软链指回上一个目录——比重新构建快，也不依赖"记得改回哪次提交"。构建号写进页面（如 `import.meta.env` 注入的版本号显示在页脚）以便用户报障时能确认版本。

### 与后端的契约
- **类型生成与错误码分支**：`openapi-typescript http://127.0.0.1:8000/openapi.json -o src/api/schema.d.ts`（开发期对本地后端、发布期对 CI 里的后端服务跑），生成物提交进库并在流水线里做"重新生成后是否有 diff"的检查，防止契约漂移。后端统一返回 `{ code, message, data, trace_id }`，前端按**码**分支而不是按 `message` 文本匹配（文案随时会改/被翻译）：至少要区分认证类（401/40100 → 走刷新或跳登录）、权限类（403/40300 → 提示无权访问，不重试）、设备离线（40901 → 提示设备离线并展示"最后一次在线时间"）、参数类（42200 → 一般是前端 bug，带上 `trace_id` 上报）、服务端（500/50000 → 可重试 + 提供"复制 trace_id"入口）；错误码到文案的映射集中在一处（`utils/errorMessage.ts`），不要散落在各组件。
- **Token 刷新与并发排队**：Access Token 短、Refresh Token 会轮换，所以**同一时刻只能有一个刷新请求在飞**——否则多个并发 401 会各自拿旧 Refresh Token 去换，后端轮换后除第一个以外的全部失败，用户被动登出。做法是模块级共享一个 `refreshing: Promise<string> | null`（示例见前文请求层）：第一个 401 创建刷新 Promise，其余请求 `await` 同一个 Promise，成功后各自带新 Token 重放（每个请求只重试一次，用 `_retried` 标记防止死循环）；刷新失败则清理本地会话并跳登录，同时把原地址放进 `redirect` 查询参数。**刷新请求本身绝不能再走 401 拦截器**，否则递归。
- **WebSocket / SSE 的前端处理**：连接建立后首帧发认证消息（不放 URL query，会进 Nginx 访问日志）；客户端每 30s 发一次心跳，服务端 90s 无数据即断开，所以要保证心跳定时器在页面切到后台时也活着（浏览器会节流后台标签页的定时器，需要按实际情况调整或用可见性事件补偿，具体行为按目标浏览器核实）；重连用**指数退避 + 抖动**：1s → 2s → 4s → 8s → 上限 30s，抖动取 0–1s 随机以打散多客户端同时重连；重连成功后先拉一次全量快照再订阅增量，不能假设断线期间的增量事件会补发乱序或缺失。事件统一带 `trace_id` 与单调递增 `seq`：前端记录已处理的最大 `seq`，遇到更小的丢弃（去重）、遇到跳号则触发一次快照补齐。界面上必须有**连接状态指示**（在线/重连中/已断开），并明确标注数据"可能不是最新"的时间，不能让用户对着过期数据做控制决策。
- **分页与乐观更新**：与后端统一 `?page=1&page_size=20`、响应含 `total`；前端要处理三件事：页码与筛选条件同步进 URL 查询参数（可分享、可刷新回原页）、竞态（快速翻页时旧请求晚到会覆盖新页，用请求序号或 `AbortController` 丢弃过期响应）、列表虚拟滚动只在真的卡顿时引入。乐观更新仅用于"失败概率低、失败可回滚、回滚用户能理解"的操作（点赞、标星、开关状态）；控制设备、下单、支付这类操作必须**等服务端确认后再改界面**并在等待期禁用按钮——乐观更新在这里会把"已下发"显示成"已执行"，与后端的四种控制结果直接冲突。

### 质量与性能
- **组件测试（Vitest + Vue Test Utils）与 E2E 入门（Playwright）**：单测测"行为与契约"而不是"实现细节"——给定 props 渲染出什么、点击触发哪个 emit、store 变更后视图如何变；断言用可见文本或 `data-testid`，不要断言内部 CSS 类名与私有变量名，否则重构必红；请求用 `msw` 类工具在 fetch/XHR 层拦截，比 mock 掉自己的 api 模块更接近真实；测试环境默认值（jsdom/happy-dom）按 Vitest 当前文档核实。E2E 只覆盖 3–5 条**关键用户旅程**（登录 → 看见列表 → 下发指令 → 收到结果；未登录访问受限页被跳转），不要用它复刻所有单测：用 role/text 定位器（`getByRole('button', { name: '停止' })`）而不是长 CSS 选择器，用自带自动等待与 web-first 断言、绝不写 `sleep`，`trace: 'on-first-retry'` 保留失败现场，CI 里只跑 Chromium 保速度，测试数据用独立账号与专用环境，**不要对着生产跑写操作**。
- **首屏与包体积**：路由级组件全部用 `() => import(...)` 动态导入，Vite 自动按路由分包；重组件（图表、富文本编辑器、地图）用 `defineAsyncComponent` 或 `import()` 在真正需要时再加载，并给加载态与失败重试。首屏预算建议：初始 JS + CSS 的 gzip 体积控制在 200KB 量级、首屏接口 1–2 个（依据是"让移动网络中端机在 2.5s 内完成 LCP"的目标，具体阈值按项目性能目标与实测调整）。指标以 Core Web Vitals 为准（LCP < 2.5s、INP < 200ms、CLS < 0.1 为"良好"阈值，取值以 web.dev 当前文档为准）：`<img>` 写死 `width`/`height` 或 `aspect-ratio` 消除布局抖动；图片提供 WebP/AVIF 与回退格式、首屏以下 `loading="lazy"`、列表缩略图用 CDN 裁剪参数而不是加载原图；字体只保留必要字重并 `font-display: swap`，自托管字体 `preload` 关键文件，中文字体体积大，优先系统字体栈。体积用 `npx vite-bundle-visualizer` 或 Rollup 可视化插件看占比，重点查"是不是把整库拉进来"（日期库、UI 组件库与图标库的全量引入）与"有没有重复版本被打两份"；把 gzip 后的体积写进 CI 阈值，超了就失败——否则体积只会上涨不会下降。
- **可访问性基础（最小可用集）**：所有交互元素用原生语义元素（`button` 而不是绑了 `@click` 的 `div`），否则键盘与读屏都用不了；可见焦点样式（`outline`）不许 `outline: none` 一删了事，要换成高对比度的自定义焦点环；图标按钮必须有可访问名（`aria-label` 或视觉隐藏文字）；图片给 `alt`（纯装饰给 `alt=""`）；表单错误用文字描述并与控件关联，不能只靠红色边框；文本与背景对比度至少 4.5:1（大字号 3:1，阈值来自 WCAG 2.x AA）；不用颜色作为唯一信息载体（在线/离线要同时给文字）；尊重 `prefers-reduced-motion`。检查手段：只用键盘走一遍主流程、浏览器 Lighthouse 的可访问性项、`axe` 类工具的自动化扫描——自动化只能查出约三分之一的问题，键盘与真机走查不可省。

### 学习写法 vs 生产写法（前端三处最典型）

前端被 review 打回的通常不是"写不出来"，而是"能跑但没有工程边界"。三处对照：

1. **状态管理**
   ① 初学者为什么这样写：所有数据（接口列表、当前用户、弹窗开关、表单草稿）全塞进一个全局 store，因为"任何组件都能拿到"，改起来最快。
   ② 企业怎么写：按三类分开放——**服务端状态**（列表、详情、分页结果）交给请求缓存层（如 TanStack Query 或自建 key 化缓存）管失效、重取、去重与并发合并；**跨组件 UI 状态**（主题、当前用户、全局提示）才进 Pinia；**单组件状态**（弹窗开关、输入草稿）留在组件内用 `ref`。
   ③ 差别原因：服务端状态带"新鲜度"与并发语义（两个组件同时请求同一接口应只发一次、写操作后该让哪些缓存失效），手写全局 store 维护这些必然出错；把局部状态也塞进全局，则任何改动都波及全应用，且无法隔离测试。
2. **请求层**
   ① 初学者为什么这样写：每个组件里直接 `fetch('/api/...')` 配各自的 `try/catch`，因为最快看到结果、不依赖任何抽象。
   ② 企业怎么写：收进单一请求层（如 `api/client.ts`）——统一基地址与超时、统一错误归一（HTTP 状态与业务错误码映射成可分支结构）、`401` 触发 Token 刷新并让并发请求排队（只发一次刷新，其余重放）、区分"可重试"（网络抖动、5xx）与"不可重试"（4xx 业务失败）、支持取消（路由切换或组件卸载时 `AbortController`）。
   ③ 差别原因：错误处理与鉴权一旦散落在几十个组件里，任何策略变化都要全量搜改，且并发刷新会引发请求风暴；收口后这些是**一处可测**的逻辑。
3. **构建与部署**
   ① 初学者为什么这样写：把接口地址甚至密钥写进前端环境变量（误以为 `VITE_` 前缀能藏起来），构建产物不带 hash，Nginx 不做缓存与路由兜底，本地点开 `index.html` 就算"上线了"。
   ② 企业怎么写：明确**进入构建产物的一切都会到达浏览器**，环境变量只放公开配置（接口基地址、埋点开关），密钥一律留在服务端；静态资源带内容 hash 并配长缓存，`index.html` 禁缓存；Nginx 用 `try_files $uri $uri/ /index.html` 兜底前端路由；包体积设阈值并在 CI 里拦截超标；多环境用同一份代码加不同注入，而不是"改代码再打包"。
   ③ 差别原因：前端没有秘密，密钥进产物等于永久泄露；而缓存与 hash 策略直接决定"发版后用户能否拿到新版本"——缺 hash 的长缓存会让用户停在旧代码上，这是线上问题里最难解释的一类。

**验收**：能指出你这三处分别在哪个文件，并解释为什么这样放；若第 1 处答不出"服务端状态为什么不该进 store"，回去重读本节与"与后端的契约"。

## 常见坑与验收标准

常见坑：① 把 Token 或"是不是管理员"的判断当安全措施——前端只做体验，鉴权必须由后端在每个接口上重判；② 把密钥写进 `VITE_` 变量并以为"打包后就看不见"，实际上原样躺在产物里；③ 多个并发 401 各自刷新 Token，触发后端轮换导致被登出；④ Nginx 没配 `try_files`，用户刷新 `/devices/123` 得到 404，而开发环境因为 Vite dev server 自带回落而毫无察觉；⑤ 用 `v-if` 与 `v-for` 同时操作同一列表却不给稳定 key，或用下标当 key，列表增删后输入框内容串位；⑥ 组件卸载后定时器/WebSocket 监听仍在跑，切路由几次后请求量翻倍；⑦ 用 `watch` 里发请求却不清理，快速切筛选条件时旧响应覆盖新数据；⑧ 把服务端数据全量复制到 store 又各处手改，出现两个不一致的真相；⑨ 用 `any` 抹平接口字段差异，改名后线上白屏而类型检查全绿；⑩ 只测了 Chrome + 桌面，上线后移动端被输入框自动放大、被工具栏遮住底部按钮。

验收项（每条都要跑出结果，不靠感觉）：
1. 未登录直接访问受限路由 → 被跳到登录页且带 `redirect`；登录成功后回到原地址而不是首页。
2. 手动构造 `40300` 与 `40901` 两个响应：分别给出"无权访问"与"设备离线（含最后在线时间）"提示，且 40901 不触发无意义重试。
3. 让 Access Token 立即过期，同时并发发出 5 个请求 → 网络面板里只有**一次**刷新请求，5 个请求全部用新 Token 重放成功；刷新接口返回 401 时清理会话并跳登录，不出现请求风暴。
4. 把后端停掉，页面给出可理解的错误文案与 `trace_id`（不是白屏或 `undefined`），且该 `trace_id` 能在后端日志里找到对应请求。
5. 断网 30s 再恢复：WebSocket 按 1/2/4/8…s 退避重连（网络面板或日志确认间隔递增且有抖动），重连后数据补齐、`seq` 跳号被检测并触发快照，界面全程显示连接状态。
6. `npm run build` 后在生产构建下刷新 `/devices/123`、`/orders/456` 等深层路径均正常（Nginx `try_files` 生效）；发布新版本后刷新页面拿到新版本（`index.html` 未被缓存），静态资源命中强缓存。
7. 只用键盘完成"登录 → 打开列表 → 触发停止 → 看到结果"全流程，焦点可见、无焦点陷阱；Lighthouse 可访问性项无严重问题。后端改掉一个字段名后 `vue-tsc --noEmit` 报错（而不是运行时才发现）；`openapi-typescript` 重新生成后无未提交 diff。
8. 记录首屏 LCP/INP/CLS 与初始包体积并写进 README，与上一次发布对比；超标时有明确归因（哪个依赖、哪张图、哪个字体）。
9. 组件测试与 E2E 在 CI 里跑通，且改一个组件的对外契约（props/emits）能造成测试失败——说明测试真的在测契约。

## 学习路径
前置：HTML 标签与表单、CSS 选择器与盒模型、JavaScript 的变量/函数/数组方法/Promise、Git（见 `02-se-foundations.md`）；后端接口形状与错误码约定见 `03-app-web-backend.md`。任一项答不上来先补，再动手写页面。
1. 用纯 HTML + CSS 静态还原一个页面（列表 + 详情 + 表单），刻意使用语义化标签、Flex 与 Grid、CSS 变量；只用键盘走一遍，先建立"结构、样式、可访问性"三层意识。
2. 加 JavaScript：`fetch` 调后端接口、渲染列表、处理 loading 与错误；把 `var` 换 `const/let`，理解事件循环为什么 `await` 在 `setTimeout(fn, 0)` 之前执行。
3. 引入 TypeScript：开 `strict`，给接口响应写类型，用联合类型收敛状态码分支，把 `any` 全部消掉；再运行 `openapi-typescript` 换成生成类型，感受"后端改名 → 前端报错"。
4. 迁到 Vue 3：把第 2 步的页面拆成 `views/ + components/`，用 Composition API 重写，练 props/emits 契约、`v-model`、插槽与 `computed`。
5. 加 Vue Router（含守卫与鉴权跳转）与 Pinia（区分"进 store"与"留在组件"），再把请求层收进 `api/client.ts`，实现拦截器、错误归一与 Token 刷新排队。
6. 用 Vite 搭起工程化骨架：环境变量、ESLint/Prettier、`typecheck` 脚本、构建产物分析；本地用 Nginx 或 `vite preview` 验证 `try_files` 与缓存头。
7. 补测试：Vitest + Vue Test Utils 覆盖 2–3 个关键组件，Playwright 覆盖 1 条主旅程；把它们接进 CI，让"契约改了测试就红"。
8. 接实时能力：WebSocket 订阅设备状态（心跳、退避重连、`seq` 去重与快照补齐、断线状态提示），并在弱网下手动验证。
9. 收尾生产化：按 Core Web Vitals 优化首屏（懒加载、图片、字体、包体积阈值），过一遍可访问性最小集，最后按 `05-server-ops.md` 的做法完成多环境发布与软链回滚演练，并把本轮的数字（包体积、LCP）记进学习档案。

### 移动端形态选型（项目形态未定，以下一律需核实）
学习者的具体项目最终要做成哪种形态**尚未确认**，因此下面只给判断维度与代价、**不替他假设**；每一条结论都要在选型时核实（途径：官方文档的能力矩阵与限制页、官方示例工程、真实设备上跑一次目标功能）。

| 形态 | 适用场景 | 主要代价 | 项目适用性 |
|---|---|---|---|
| H5（移动端网页） | 已有 Web 前端、功能以展示与轻交互为主、需要"发链接就能用"、要同时兼容桌面 | 无法用系统级能力（后台推送、蓝牙、部分传感器需浏览器授权）；弱网与首屏体验受浏览器限制；iOS 上部分能力受限 | `待核实` |
| 微信小程序 | 用户主要在微信内使用、依赖微信登录/支付/分享、无需复杂系统权限 | 受平台框架与审核约束，能力边界与发布节奏由平台决定；代码不能直接复用到其他端 | `待核实` |
| uni-app（小程序 + H5 + APP 一套代码） | 需要同时覆盖小程序与 APP 且团队只有前端人力、接受用条件编译处理平台差异 | 跨端抽象带来平台差异与性能损耗，遇到平台特有能力时仍需写原生/插件；调试链路更长 | `待核实` |
| React Native | 需要接近原生的交互与性能、要用原生模块（BLE、后台定位）、团队能接受 RN 生态与升级成本 | 与 Vue 技术栈不同源（要写 JSX/React）；原生依赖与构建环境有额外维护成本 | `待核实` |

选型建议的**判断顺序**（不预设答案）：先写清"必须用到的系统能力"（推送、蓝牙、后台运行、摄像头/传感器）→ 再定"用户从哪里进入"（微信内 / 应用商店 / 浏览器链接）→ 再看团队现有技术栈与能承受的维护面 → 最后才比较框架。设备控制类项目里，蓝牙/局域网直连与后台常驻往往是决定性约束，而这三项的准确能力边界必须以目标平台**当前官方文档**为准，不能凭印象：`待核实`。
