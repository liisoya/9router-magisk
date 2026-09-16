# 9Router 安卓模块（Magisk / KernelSU / APatch）

把 [decolua/9router](https://github.com/decolua/9router) 以**系统级常驻服务**的形式跑在安卓上：
内置 arm64 版 Node 运行时，直接使用**上游官方发布的预构建产物**（不需要在手机上 or 电脑上编译 Next.js）。

- 开机自启、崩溃自愈、健康检查、日志轮转
- 设备内一键更新 9Router 应用（带 sha512 校验、失败自动回滚）
- 自带控制面板（状态 / 启停 / 密码 / 局域网开关）
- 本机 + 局域网同时可用

---

## 1. 运行要求

| 项 | 要求 |
|---|---|
| 架构 | **仅 arm64-v8a**（非 arm64 会在安装时直接拒绝） |
| 系统 | Android 7.0+（实测 Android 16 / SDK 36） |
| Root | Magisk / KernelSU / APatch（实测 ReSukiSU v4.1.0 + hybrid_mount metamodule） |
| 空间 | 首次约 150MB；每多留一个版本 +57MB |
| 网络 | 首次启动不需要联网；在线更新应用时才需要（设备自身能访问 registry.npmjs.org） |

> 安装请通过 Magisk / KernelSU / APatch 的**管理器 App**「从本地安装」模块 zip，不要用 recovery 直刷。

---

## 2. 安装与首次使用

1. 管理器 App → 模块 → 从本地安装 → 选择 `9router-Magisk-<版本>.zip`（例如 `9router-Magisk-0.5.75-r1.zip`）
2. 重启手机（模块的 `service.sh` 会在开机完成后自动拉起服务）
3. 打开控制面板：`http://<手机IP>:20129`
4. 打开 Dashboard：`http://<手机IP>:20128/dashboard`，**默认密码 `123456`**

在手机本机上访问也可以用 `http://127.0.0.1:20128/dashboard`。
忘了密码时：模块详情页的描述里会显示当前密码，或执行 `9router status`。

---

## 3. 局域网使用（重要）

上游对**非 loopback** 的 `/v1/*` 请求强制要求 API Key，所以电脑/其他设备要调用必须带 key：

```bash
# 手机上生成一个 key（会自动写入配置并显示）
9router key                 # 或 9router key 我的电脑

# 电脑上使用
curl -H "Authorization: Bearer sk-xxxx" http://<手机IP>:20128/v1/models
```

把它填进任意 OpenAI 兼容客户端即可：`Base URL = http://<手机IP>:20128/v1`、`API Key = sk-xxxx`。

Dashboard 网页端不受此限制，用密码登录即可。

---

## 4. 命令速查（终端）

调用路径：`9router`（依赖模块 overlay 挂载）。若提示找不到命令，用完整路径
`/data/adb/modules/9router/system/bin/9router`。

| 命令 | 作用 |
|---|---|
| `9router status` | 版本 / 进程 / 地址 / 当前密码 / 局域网 Key |
| `9router start` `stop` `restart` | 启停服务（由守护进程执行） |
| `9router log [行数]` | 查看服务日志 |
| `9router update [版本]` | **在线更新应用**（默认取上游最新正式版） |
| `9router update-local <文件>` | 用本地 tarball 安装（离线/代理场景） |
| `9router rollback` | 回滚到上一个版本 |
| `9router versions` | 列出已安装的版本 |
| `9router setpw <密码>` | 修改 Dashboard 密码（同步显示到模块描述） |
| `9router key [名称]` / `keys` | 创建 / 列出台网 API Key |
| `9router lan on\|off` | 开放局域网 / 仅本机 |
| `9router ui on\|off` | 开关控制面板 |

---

## 5. 更新机制

**应用更新（日常用这个）** —— 不需要重刷模块，数据与配置全部保留：

```bash
9router update            # 拉取上游最新版
9router update 0.5.69     # 指定版本
9router rollback          # 出问题一键回退
```

流程：查 npm 元数据 → 下载约 14MB 的官方包 → **sha512 完整性校验** → 解到 `versions/<新版本>/app` →
切换软链 → 重启 → 健康检查；**检查不通过会自动回滚上一版本**。

**模块自身更新（脚本 / 守护 / 运行时 / 出厂版本）** —— 无法在设备内自更新，走 Release + 管理器提示：

- 仓库根目录的 `update.json` 会随每次打包自动生成，`module.prop` 里的 `updateJson` 指向它；
- 把 `dist/9router-Magisk-<版本>.zip` 作为 Release 附件上传（tag 形如 `v0.5.75-r1`）；
- 之后 Magisk / KernelSU 的模块列表会显示可更新，点一下就能升级模块（应用数据不受影响）。

---

## 6. 配置文件与目录

```
/data/adb/modules/9router/         # 模块本体（重装/刷新版会整体替换）
  runtime/bin/node.bin             # arm64 Node 运行时（随模块更新，不单独升级）
  runtime/lib/*.so, cacert.pem     # 运行时依赖与 CA
  versions/<版本>/app              # 上游预构建产物（每个版本一份）
  app -> versions/<版本>/app       # 当前生效版本（软链）
  default-version                  # 出厂默认版本
  control-center.cjs apikeys.cjs   # 面板 / 密钥工具
  supervisor.sh service.sh ...     # 守护与生命周期脚本

/data/adb/9router/                 # 数据区（重装模块不丢）
  env.sh                           # 配置（0600）
  data/                            # DATA_DIR：db/data.sqlite、backups、machine-id、jwt-secret
  tmp/                             # 临时目录
  log/service.log(.old)            # 日志，512KB 自动轮转
  backups/                         # 更新前的数据库快照
  current-version / prev-version   # 版本指针
```

`env.sh` 可调项：

| 变量 | 默认 | 说明 |
|---|---|---|
| `APP_PORT` | 20128 | Dashboard + `/v1` 端口 |
| `UI_PORT` | 20129 | 控制面板端口 |
| `BIND_HOST` | `0.0.0.0` | 监听地址（`127.0.0.1` 表示仅本机） |
| `INITIAL_PASSWORD` | `123456` | Dashboard 初始密码 |
| `REQUIRE_API_KEY` | `false` | 是否对 `/v1` 强制鉴权（远端本来就会强制） |
| `API_KEY` | 空 | 推荐的局域网 Key（`9router key` 写入） |
| `MAX_OLD_SPACE` | 512 | Node 堆上限（MB）。**上游默认写死 6144**，手机上过大反而危险 |
| `UV_THREADPOOL_SIZE` | 2 | 线程池大小 |
| `PANEL` | 1 | 是否随服务拉起控制面板 |

改完执行 `9router restart` 生效。

---

## 7. 从源码构建 zip

```bash
bash tools/fetch-runtime.sh    # 取 Termux 官方 aarch64 Node + 依赖（SHA256 校验）
bash tools/fetch-app.sh        # 取上游 npm 预构建产物（sha512 校验）
bash tools/build-module.sh     # 组装 → dist/9router-Magisk-<版本>-r<修订>.zip（并刷新根目录 update.json）
```

版本源只有一个文件 `versions.env`：

```ini
APP_VERSION=0.5.75      # 跟随上游，改这里即可
MODULE_REV=1            # 模块脚本自身的修订号
NODE_PACKAGE=nodejs-lts
NODE_VERSION=24.18.0-1  # 必须 ≥22.5（依赖内置 node:sqlite）
```

查询上游是否有新版（只读，不会自动改文件）：

```bash
bash tools/check-update.sh          # 打印当前/最新
bash tools/check-update.sh --bump   # 顺手把 versions.env 改成最新版
```

网络不通时：`export PROXY=socks5://127.0.0.1:7890`。

---

## 8. 卸载

管理器里移除模块即可（会先停掉守护进程、服务与面板）。

数据默认保留在 `/data/adb/9router`（配置、数据库、日志），需要彻底清除：

```bash
rm -rf /data/adb/9router
# 或卸载前执行: sh /data/adb/modules/9router/uninstall.sh purge
```

---

## 9. 已知限制

- **仅 arm64-v8a**；不支持 32 位 ARM 与 x86 模拟器。
- 局域网调用 `/v1` **必须带 API Key**（上游策略，非本模块限制）。
- 模块脚本层更新需要重刷 zip；设备内只能更新应用层。
- `9router` 命令依赖 system overlay 挂载（hybrid_mount / Magisk 的 magic mount）。若没挂上，
  用完整路径调用即可，不影响服务运行。
- 上游 Dashboard 里的“自更新 / 隧道 / MITM 证书 / CLI 工具配置写入”等功能是面向 PC 设计的，
  在安卓上多数不可用；本模块只保证**网关、Dashboard、路由与热更新**这几条主线。
- 默认堆上限 512MB（上游为 6144MB）。跑超长上下文可上调 `MAX_OLD_SPACE`。

---

## 10. 故障排查

| 现象 | 处理 |
|---|---|
| 面板/接口打不开 | `9router status`；日志 `/data/adb/9router/log/service.log` |
| 端口被占用 | 日志会出现 `EADDRINUSE`；`9router restart`，或改 `APP_PORT` |
| 局域网 401 | 正常现象，需要 API Key：`9router key` |
| 忘记密码 | 模块详情页描述 / `9router status` 显示当前密码 |
| 更新后起不来 | 已自动回滚；也可手动 `9router rollback` |
| 想彻底重置 | 停服务 → `rm -rf /data/adb/9router` → `9router restart` |

---

## 11. 目录说明与致谢

本仓库：**https://github.com/liisoya/9router-magisk**（由该项目自行维护，不再跟随参考实现）。

起点是 [Aydin04/9router-magisk](https://github.com/Aydin04/9router-magisk)（其“内置 Node + supervisor”思路给了很好的参考），
已重写为：使用上游 npm 预构建产物、Node 取自 Termux 官方仓库并做校验、补齐健康检查/日志轮转/回滚/更新提示。
仓库里的 `magisk-module/`、`scripts/`、`extra-assets/` 为参考实现的遗留文件，**当前构建流程不使用**。

- 9Router 本体：[decolua/9router](https://github.com/decolua/9router)（MIT）
- Node 运行时与依赖：Termux 官方仓库（packages.termux.dev）
- 详细的方案与权衡记录见 [`DESIGN.md`](./DESIGN.md)
- 第三方组件许可见 [`module/NOTICE`](./module/NOTICE)

> 本模块以 root 常驻运行，默认监听 `0.0.0.0`。若设备在陌生网络下使用，建议
> `9router lan off` 或至少确认 `9router key` 已设置。
