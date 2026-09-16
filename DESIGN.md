# 9Router 安卓化设计方案 v2（Magisk / KernelSU）

目标：把上游 [decolua/9router](https://github.com/decolua/9router) 以 root 模块形式常驻运行在 Android（arm64），
**并且能低成本跟随上游版本更新**；本机（Termux / root shell）与局域网（LAN）均可用。
本方案以第三方实现 [Aydin04/9router-magisk](https://github.com/Aydin04/9router-magisk) 为参考基线并做修正。

---

## 0. 已实测的关键事实

| 结论 | 证据 |
|---|---|
| **不需要自己 build** | 官方 npm 包 `9router@0.5.75`（14MB tarball，integrity `sha512-dyFdRBvDZ…`）内含 `app/`：完整 Next.js standalone 预构建产物（`server.js`、`custom-server.js`、`.next-cli-build/`、`public/`、`src/`、`node_modules/` 子集，57MB） |
| **可直接跑** | PC 上 `HOME=… node custom-server.js`：Next.js 16.3.4 Ready，`/v1/models` → 200，`/dashboard` → 307（跳登录），空闲 RSS ≈ **7.7MB** |
| **无需任何原生模块** | 日志明确 `[DB] better-sqlite3 unavailable → [DB] Driver: node:sqlite`，落到 Node 内置 sqlite。前提是 **Node ≥ 22.5** |
| Node 运行时可自持 | Termux 官方源 aarch64：nodejs-lts 24.18.0-1 / openssl 3.6.3 / libicu 78.3 / libc++ 29 / c-ares 1.34.8 / libsqlite 3.53.4 / zlib 1.3.2 / ca-certificates 2026.08.13 |
| 设备侧工具齐全 | 目标机 adb shell 自带 `tar` `gzip` `unzip` `curl`（toybox）→ **设备端热更新可行** |
| 第三方模块的“Ultra-Lite”开关是无效的 | `NINEROUTER_ENABLE_LIVE_WS`、`DISABLE_DASHBOARD_SSR`、`NINEROUTER_API_KEY`、`TARGET_MAX_RAM`、`enable_ui` 在上游源码命中数均为 **0** |
| ⚠️ 当前目标设备未 root | 小米 `missi-user` / Android 16 / arm64-v8a / SELinux Enforcing；无 `su`、无 `/data/adb`、无 Magisk/KSU/APatch → **刷模块前必须自行 root** |

---

## 1. 三层架构

```
┌─ runtime/  Node LTS 24 (bionic) + libcrypto/libssl/libicu/libc++/cares/sqlite/z + cacert.pem
│            └─ 来源：packages.termux.dev 官方 deb，版本 pin + SHA256 校验
├─ app/      上游预构建产物（= 上游版本号），整体可替换
└─ module/   安装/自启/守护/配置/更新/启停（对外唯一入口 `9router`）
```

设备上布局：

```
/data/adb/modules/9router/
  runtime/bin/node.bin            # 只读运行时
  runtime/lib/*.so, cacert.pem
  versions/0.5.75/…               # 每版一份应用产物
  versions/0.5.79/…
  app -> versions/0.5.75          # 原子切换（symlink）
  module.prop  service.sh  action.sh  uninstall.sh
  supervisor.sh  www/control-center.cjs(可选)
/data/adb/9router/                # 数据区（模块外，更新/重装不丢）
  data/                           # DATA_DIR：db/data.sqlite、backups、machine-id、jwt-secret
  tmp/                            # TMPDIR
  log/service.log                 # 轮转 512KB ×2
  env.sh                          # 配置（0600）
```

`HOME=/data/adb/9router`、`TMPDIR=…/tmp`、`DATA_DIR=…/data`（**HOME 必须显式设置**，root 进程 HOME 常为空会导致 `~/.9router` 落到 `/`）。

---

## 2. 版本与更新策略（手动优先）

单一版本源 `versions.env`：

```
APP_VERSION=0.5.75        # 跟随上游 npm 版本
NODE_VERSION=24.18.0-1    # Termux nodejs-lts
TERMUX_DEBS="openssl 1:3.6.3 libicu 78.3 ..."   # 逐个 pin + sha256
```

**更新一律手动触发，不设定时任务**（省 CI 资源、避免半夜自动推包）：

| 层 | 内容 | 触发方式 | 成本 |
|---|---|---|---|
| L1 模块本体 | 脚本、Supervisor、默认配置 | 我点 `workflow_dispatch` 跑 `build.yml` | 重建 zip |
| L2 应用跟随上游 | **换 npm 版本号即可** | 手动：`check-update.yml`（打印上游最新并可自动开 PR）→ 我确认 → `build.yml` | 重建 zip |
| L3 设备端热更新 | `9router update`（不刷机、不清数据） | 你在手机上手动执行，或 Magiskaction 菜单 | 仅下 14MB，无 CI |

- **无任何 cron / schedule**：CI 默认不运行；只有 `workflow_dispatch` 触发。
- **默认版本检测是"查询"不是"推送"**：设备端 `9router check-update` 只比对并提示，不改动任何文件。
- **回滚**：保留 N-1（默认 2 份），`9router rollback`；新版本启动失败自动回退。
- **引脚校验**：npm `dist.integrity`(sha512)、Termux deb 的 `Packages` SHA256，两处都校验后才落地。

> 结论：上游发版 ≠ 我们自动跟风；想更新时跑一次任务即可，单次构建约 1–2 分钟，产物=Github Release(draft)。


---

## 3. 相对第三方模块的改进清单

| # | 项 | 第三方现状 | 本方案 | 理由 |
|---|---|---|---|---|
| 1 | Node 来源 | clone 第三方预编译仓库，无 pin/无校验 | Termux 官方 deb + SHA256 | 供应链风险，且可复现/可升级 |
| 2 | 应用来源 | 本地 `npm install` + `next build` | 官方 npm 预构建 `app/` | 从 10+ 分钟构建降到秒级；产物可复现 |
| 3 | 版本锁死 | 写死 0.5.39 | `versions.env` + 自动检测 | 跟随上游 |
| 4 | 监听地址 | 默认 `0.0.0.0` | 默认 `127.0.0.1`，LAN 需显式开启 | 你要 LAN，但默认不该裸奔 |
| 5 | 鉴权 | 默认 key `dsh-local-key`、无初始化密码 | 安装时随机生成 API key / INITIAL_PASSWORD / JWT_SECRET，0600 存储 | `123456` 与固定 key 等同开放 |
| 6 | 控制面板 | `0.0.0.0:20129` 无鉴权 | 默认仅 loopback + token；或默认关闭（上游 Dashboard 已够用） | root 面板暴露在 LAN 是最严重的问题 |
| 7 | 数据权限 | `set_perm_recursive … 0777 0777` | `0700`（root 独占） | 任意 App 可读改你的 provider 密钥 |
| 8 | 启动脚本 | `while true` 阻塞式 + `exec >> log` 无轮转 | `service.sh` 后台拉起 supervisor 后退出；日志 512KB×2 轮转；崩溃指数退避重启 | 阻塞 boot 阶段、日志可能吃满 /data |
| 9 | 安装方式 | `SKIPUNZIP=1` + `tar` 管道 + 探测 busybox | 标准解压（或自带 tar 降级） | 少一个外部依赖 = 多一份兼容性 |
| 10 | 无效开关 | 设置无人读取的环境变量 | 删除；仅保留真实项（`UV_THREADPOOL_SIZE`、`oom_score_adj -700`、V8 flags） | 避免“看起来有效”的错觉 |
| 11 | 额外 providers 补丁 | 强改 registry/图标 | **默认关闭**，与上游保持一致 | 上游结构变化会打挂补丁，妨碍自动跟随更新 |
| 12 | 卸载 | 数据目录保留且 0777 | `uninstall.sh` 停服并清理进程；询问保留配置（无论保留与否都改权限） | 卫生与明确性 |

### 3.1 第三方做法中值得保留的部分（已逐条验证真实性）

| 做法 | 真实性 | 保留方式 |
|---|---|---|
| supervisor `while true` 崩溃自动重启 | ✅ 真实且必要 | 保留，但**移到独立后台进程**（不阻塞 boot），并加指数退避 + 崩溃风暴熔断 |
| `echo -700 > /proc/<pid>/oom_score_adj` | ✅ 真实（降低被 LMK 选中概率） | 保留 |
| `UV_THREADPOOL_SIZE` | ✅ Node 原生变量（默认 4 线程，调 2 省内存） | 保留，默认 2 |
| V8 `--max-old-space-size` / `--max-semi-space-size` / `--optimize-for-size` | ✅ 真实，但**只在负载上升时才有意义** | 保留为可配置项，默认给出保守值（见下） |
| 控制面板（独立 Node 进程） | ✅ 占用很小 | **默认开启**（你的决定）；额外用 `--max-old-space-size=32` + `UV_THREADPOOL_SIZE=2` 约束 |
| "删构建垃圾" 的思路 | ✅ 思路对 | 但用 npm 预构建产物后垃圾本就极少（实测：0 个 sourcemap、0 个 `.d.ts`、无 `.next/cache`），因此**不做激进 purge**（避免删坏运行依赖） |
| `router_config.env` 每轮重读、改配置不改包 | ✅ 真实有用 | 保留，改为 `/data/adb/9router/env.sh`（0600） |
| 剥离指定了却无效的开关 | ❌ 无效 | **删除**（见上表 #10） |

**额外的"少垃圾"收益：必须删掉 `app/cli/`**
官方 npm 包里残留了打包机器的 `app/cli/.build-home/`，内含构建机自己的 `.9router/db/data.sqlite`、`jwt-secret`、`machine-id`。
这不只是垃圾——所有安装者共享同一个 `machine-id`（云同步会串）。构包时**强制删除该目录**。

### 3.3 内存上限怎么定（官方做法 vs 安卓取舍）

**官方的做法**（`cli/cli.js:615`，同时也是 npm CLI 里的启动方式）：

```js
spawn(RUNTIME, ["--dns-result-order=ipv4first", "--max-old-space-size=6144", serverPath], …)
```

- 只有这两个参数：**ipv4 优先 + 堆上限固定 6144MB**，此外没有设置任何 `NODE_OPTIONS`。
- **没有按机器内存动态调整**（全仓库无 `os.totalmem()` / `os.freemem()` 调用）。
- **没有针对不同模型/提供商做区分**：模型只影响路由、翻译和配额，不影响进程内存策略。
- Dockerfile 里也**没有任何 V8 参数** → 容器里走 Node 默认堆。

**安卓上的取舍**：照抄 6144 在手机上很危险（等同于放任堆增长到被 LMK 连同服务一起杀掉）。
本方案默认 `--max-old-space-size=512`（可在 `env.sh` 调整），理由：
- 空闲实测仅 ~8MB，堆上限只在「大上下文 / 大 payload / 日志历史」时才会接近；
- 512MB 足以覆盖 Next SSR + RTK 数据流 + 常规上下文；若你常跑超长上下文，改成 768/1024 即可；
- 真被 OOM 杀掉时 supervisor 会记录并自动重启（重启失败则回滚上一版本），不会静默失效。

> 我们保留官方的两个原生参数（`--dns-result-order=ipv4first`、`--max-old-space-size`），只是把上限值从 6144 降到手机友好的量级。

| 场景（PC 上跑同一份 npm 预构建产物） | 空闲 RSS |
|---|---|
| 默认参数 | ≈ 7.7 MB |
| `UV_THREADPOOL_SIZE=2` + `--max-old-space-size=256 --max-semi-space-size=1 --optimize-for-size` | ≈ 7.6 MB |
| `--max-old-space-size=128` | ≈ 7.6 MB |

结论：**9Router 本身已经很轻（约 8MB 空闲）**，第三方宣传的"Ultra-Lite 省内存"实际并无开关在起作用。
真正决定长时间运行内存的是「堆上限 + 进程数量」，因此本方案的省内存手段是：

1. **进程数量固定为 2 个**：本体 + 控制面板（你的决定），两个进程都单独限制堆（本体 512MB / 面板 32MB）；
2. 给堆设上限（默认 `--max-old-space-size=512`，可在 `env.sh` 调整；官方是 6144），避免 LLM 大上下文/日志累积把内存吃爆后被 LMK 杀掉；
3. `UV_THREADPOOL_SIZE=2`、`NEXT_TELEMETRY_DISABLED=1`、`oom_score_adj=-700`；
4. **健康检查**：supervisor 每 60s 用本机 HTTP 探活（`/v1/models` 带 key），连续失败才重启——比"只看进程是否还在"更可靠；
5. **单实例锁**：PID 文件 + `kill -0` 校验，避免 Repeated start 出现多进程抢端口；
6. **日志 512KB ×2 轮转**（防止 `/data` 被日志吃满——第三方的致命遗漏）；
7. IPv4 优先 `--dns-result-order=ipv4first`（安卓常见 IPv6 假可用导致上游请求卡住）。

---

## 4. 默认运行参数（本机 + LAN 都要，安全从简）

```
PORT=20128
BIND_HOST=0.0.0.0            # 默认同时对本机与局域网开放
REQUIRE_API_KEY=false        # 默认与上游一致：不强制 API Key（可在面板/设置里开启）
INITIAL_PASSWORD=123456      # 沿用上游默认初始密码，用户可在面板自行修改
JWT_SECRET=<安装时生成>       # 仅用于 cookie 签名，不需要记住
```

**密码可见性（按你的要求）**：初始密码固定 `123456`，且无论用户改成什么，都**不怕忘**——
- `module.prop` 的 `description` 里直接显示当前 Dashboard 密码（每次改密码后由 `9router setpw` 回写更新）；
- Magisk/KernelSU 模块详情页与 `9router info` 也会显示；
- 这样既不记在脑子里，也不依赖外部文件。

> 仅保留一处安全底线：`JWT_SECRET` 在安装时随机生成（它不参与登录，丢了无所谓，但避免所有人共用同一个签名密钥——官方 npm 包里就残留了打包机的 `jwt-secret`，我们不用它）。


---

## 5. 构建流程

```
tools/fetch-runtime.sh   # 按 versions.env 下 deb → SHA256 校验 → 解包 → 抽最小动态库闭包
tools/fetch-app.sh       # npm pack 9router@<ver> → 校验 dist.integrity → 取 package/app
                         #   └─ 强制删除 app/cli/（打包机残留的 db/jwt-secret/machine-id）
tools/build-module.sh    # 组装目录 → 注入版本/versionCode → zip
```
- 已核实的最小依赖闭包（node 的 `DT_NEEDED`）：
  `libz.so.1 libcares.so libsqlite3.so libcrypto.so.3 libssl.so.3 libicui18n.so.78 libicuuc.so.78 libicudata.so.78 libc++_shared.so`
  （`libc/libm/libdl` 由 bionic 提供），外加 `cacert.pem` + `openssl.cnf`。
- 已知体积：**runtime ≈ 88MB**（node 44MB + libicudata 33MB 占大头），**app ≈ 57MB/版本**；
  模块 zip 约 60MB，设备解包后约 145MB，保留 N-1 版本时约 200MB。
- 官方预构建产物本身很干净（0 sourcemap / 0 `.d.ts` / 无 `.next/cache`），**只做定向清理，不做激进 purge**。

CI（`.github/workflows/`，**全部 `workflow_dispatch`，无 schedule**）：
- `build.yml`：输入 `APP_VERSION`（可选，留空用 `versions.env`）→ 取 Runtime + App → 校验 → 组装 → Release(**draft**)
- `check-update.yml`：手动点 → 打印上游 npm 最新版本及当前差异；可选 `--open-pr` 直接开 PR 改 `APP_VERSION`

---

## 6. 真机验证记录（2026-09-16）

**环境**：小米 25091RP04C，Android 16 (SDK36)，arm64-v8a，SELinux Enforcing，ReSukiSU v4.1.0 +
`hybrid_mount` metamodule + `susfs4ksu` + `zygisksu`。root 通道实测可用：
`/data/adb/ksu/bin/busybox sh -c …` → `uid=0(root) context=u:r:ksu:s0`（`/system/bin/su` 仍被隐藏）。

| # | 验证项 | 结果 |
|---|---|---|
| 1 | aarch64 Node 运行时可跑 | ✅ `node.bin -v` → **v24.18.0** |
| 2 | 官方预构建 app 在安卓上启动 | ✅ Next.js 16.3.4 Ready（`custom-server.js`） |
| 3 | `/v1/models` | ✅ **200** |
| 4 | `/dashboard` | ✅ **307**（跳转登录，符合预期） |
| 5 | SQLite 驱动 | ✅ 落到内置 `node:sqlite`，生成 `db/data.sqlite`（**无需任何原生模块**） |
| 6 | 内存占用 | ✅ 刚启动 **RSS ≈ 3.8MB** |
| 7 | 调试期端口冲突 | ⚠️ 测试过程中残留监听导致 `EADDRINUSE`（我自己反复重启造成的测试产物，不是产品缺陷） |

**踩到并实现层必须处理的坑**

1. **`adb shell` 里起的进程，会话结束会被杀**
   → 因此常驻必须由 **模块的 `service.sh`（别 shell：`setsid`）** 拉起 supervisor，不能指望 adb shell。
2. **`adb push` 会把库里的 symlink 变成悬空/错位**（且目标目录已存在时会压成 `<dir>/<dir>/`）
   → 构包时**先把所有 symlink 解引用成实体文件**（`libsqlite3.so`、`libz.so.1`、`libicu*.so.78` 都要实体化；libicudata 33MB 会被复制两份，构包阶段做去重）。
3. root 上下文是 `u:r:ksu:s0`（非 `u:r:su:s0`），写 `/data/adb/*` 与绑端口均正常，脚本不要假设路径里有 `magisk`。

**剩余待验证**：LAN（`BIND_HOST=0.0.0.0`）下的联通性、supervisor 自动拉起、日志轮转、
热更新与回滚、模块用 `hybrid_mount` 挂载后的实际行为。——这些要在真模块刷入后做。

---

## 7. 已确定 / 待确认

**已确定**
- 更新策略：仅手动触发，无定时任务；Release 保持 draft 由人工发布。
- 应用程序来源：官方 npm 预构建产物（不自 build），版本即上游版本。
- Node 运行时：Termux 官方 deb + SHA256 校验，摒弃第三方预编译仓库。
- 控制面板：**默认开启**（占内存很小），独立进程 + 32MB 堆。
- 鉴权从简：默认 `BIND_HOST=0.0.0.0`、不强制 API Key、`INITIAL_PASSWORD=123456`（可在面板改），密码在 Magisk 模块介绍里显示以免遗忘。
- 更新方式：**内置设备端热更新**（不重刷模块，更新后自动重启服务，失败回滚）。
- 内存上限：默认 512MB（官方为固定 6144，且不区分模型，也不按机器内存动态调整；详见 §3.3）。
- 仓库形态：在第三方仓库基础上重写 `module/` 与 `tools/`；上游源码不进 submodule。

**唯一的外部阻塞点：~~adb shell 拿不到 root~~** ✅ 已解决
设备确为 root（`com.resukisu.resukisu` v4.1.0 + `com.abk.kernel` + `hybrid_mount` metamodule + `susfs4ksu` + `zygisksu`）。
`/system/bin/su` 仍被 SUSFS 隐藏，但可用 KernelSU 自身通道获取 root：
`/data/adb/ksu/bin/busybox sh -c …` → `uid=0(root) context=u:r:ksu:s0`。

---

## 8. 方案缺口补充（评审后新增的决策）

| # | 缺口 | 处理决策 |
|---|---|---|
| 1 | 架构范围未定义 | **仅 arm64-v8a**。32 位 arm / x86_64 模拟器不支持（`customize.sh` 检测到非 arm64 直接拒绝安装并提示）。Termux 官方也只维护 arm64 与旧的 arm/x86 不全的版本。 |
| 2 | 控制面板用谁的实现 | **不用第三方原文件**：它写死 `dsh-local-key`、写死 `/data/adb/9router-data`、并用 `exec` 拼命令行。我们自己写一个精简版（状态/启停/版本切换/显示密码），命令走白名单，不做自由 shell 执行。 |
| 3 | 上游内置自更新（`src/lib/updater`）可能改写应用目录 | 应用目录放 `versions/<ver>`（更新写新目录再切 symlink），即使被自更新写坏，`9router rollback` 立刻回到上一版。 |
| 4 | 版本号/versionCode 规则缺失 | `version = <上游版本>-r<模块修订>`（如 `0.5.75-r1`）；`versionCode = (minor*1000 + patch)*10 + rev` → 0.5.75-r1 = `50751`。 |
| 5 | 设备端热更新遇到代理/离线怎么办 | 主路径仍是 Magisk/KSU 刷新版 zip；设备端 `9router update` 走直连 npm（toybox curl 只支持 http proxy，不支持 socks5）；兜底提供 **`9router update-local <file>`**：PC 上拉好包 `adb push` 进去安装。 |
| 6 | 开源许可声明（第三方没有） | 模块内附 `NOTICE`：Node.js(MIT)、OpenSSL(Apache-2.0)、ICU、libc++、c-ares、SQLite(PD)、zlib，并注明来自 Termux 官方包。 |
| 7 | 挂载兼容性（本机是 hybrid_mount） | **默认不依赖 system overlay**：服务本身全在模块目录内；`system/bin/9router` 仅作为便利入口，即使 hybrid_mount 没挂载也不影响运行。 |
| 8 | 健康检查在无/有 API Key 两种情况 | supervisor 统一探 `/v1/models`；若 `REQUIRE_API_KEY=true`，从 `env.sh` 读取 key 带上 Authorization。 |
| 9 | 更新前的数据安全 | 热更新/回滚前把 `data/db/` 快照到 `data/backups/`。 |
| 10 | 上游 distro 目录名可能变化（今天是 `.next-cli-build`） | 脚本**不假设目录名**：直接整体替换 `versions/<ver>` 目录内容。 |
| 11 | 端口被占用 / 多实例 | 启动前检查端口；supervisor 用 PID 文件 + `kill -0` 做单实例锁，避免重复拉起抢端口。 |
| 12 | 网络 | 构建机直连 npm/Termux 已验证可达（200）；若失败自动回退 `PROXY=${PROXY:-socks5://127.0.0.1:7890}`。 |

---

## 9. 构建与发布（维护者向，用户不必关心）

### 9.1 本地构建

```bash
bash tools/fetch-runtime.sh    # 取 Termux 官方 aarch64 Node + 依赖（SHA256 校验，仅首次/换 Node 版本）
bash tools/fetch-app.sh        # 取上游 npm 预构建产物（sha512 校验，换 9Router 版本时）
bash tools/build-module.sh     # 组装 → dist/9router-Magisk-<版本>.zip，并刷新根目录 update.json
```

版本源是唯一文件 `versions.env`：`APP_VERSION`（跟随上游）、`MODULE_REV`（模块脚本自身修订）、
`NODE_PACKAGE` / `NODE_VERSION`（须 ≥22.5，依赖内置 `node:sqlite`）、`GITHUB_REPO`、`ZIP_BASENAME`。

查询上游是否有新版（只读）：

```bash
bash tools/check-update.sh          # 打印当前/最新
bash tools/check-update.sh --bump   # 顺手把 versions.env 改成最新版
```

网络受限时：`export PROXY=socks5://127.0.0.1:7890`（构建机直连可用时无需设置）。

### 9.2 发布流程

```bash
git add -A && git commit -m "chore: bump to <新版本>"
git push origin main                       # 必须推 main：update.json 通过 raw/main 被管理器读取
git tag v<新版本> && git push origin v<新版本>
gh release create v<新版本> dist/9router-Magisk-<新版本>.zip \
  --title "9Router Magisk <新版本>" --notes "变更说明"
```

约束与注意：
- **附件名必须等于 `update.json` 里的 `zipUrl` 文件名**（构建脚本已保证一致）；
- 必须是**最新（latest）**的正式 Release，否则 `releases/latest/download/…` 会 404；
- 只发 Release 不推 `main`，管理器读到的仍是旧版本信息；
- 仓库根目录的 `update.json` 由 `build-module.sh` 每次构建自动重写，不需要手改。

### 9.3 已验证的发布闭环

`module.prop` 的 `updateJson` → `raw.githubusercontent.com/…/main/update.json` →
`github.com/<repo>/releases/latest/download/9router-Magisk-<版本>.zip` → Release 附件，四处名字一致。
首个自维护版本 `v0.5.75-r1` 已按此流程发布并验证（`update.json` 200、下载链接 200）。

### 9.4 从 README 移出的其他内容

- 运行时/应用的下载与校验细节、目录结构、`env.sh` 每一项含义：见本文档 §5、§6；
- 控制面板与密码策略、LAN 与 API Key 的关系：见 §4 与 §3.1；
- 真机验证记录与踩坑清单：见 §6（验证记录）与 §8。
