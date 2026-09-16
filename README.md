<div align="center">

# 9Router 安卓模块（Magisk / KernelSU / APatch）

**把 [9Router](https://github.com/decolua/9router) 变成手机上的常驻 AI 网关。**

[![Release](https://img.shields.io/github/v/release/liisoya/9router-magisk?label=Release&color=blue)](https://github.com/liisoya/9router-magisk/releases/latest)
[![License](https://img.shields.io/github/license/liisoya/9router-magisk?label=License)](./LICENSE)
![Platform](https://img.shields.io/badge/Platform-arm64--v8a-orange)
![Android](https://img.shields.io/badge/Android-7.0%2B-3ddc84)

[**English**](./README.en.md) | 中文

</div>

装上这个模块并重启后，手机就是一台 7×24 运行的 9Router 服务：手机本机的工具（Termux / CLI）和同一局域网里的电脑都能直接调用它，无需电脑常开。

---

## 来源

- 服务本体：[decolua/9router](https://github.com/decolua/9router)（MIT）——**直接使用官方发布的预构建产物，不改源码**
- 本模块：https://github.com/liisoya/9router-magisk
- 起步于 [Aydin04/9router-magisk](https://github.com/Aydin04/9router-magisk) 的思路（内置 Node + 守护进程），后重写为免构建、可校验、可在设备内更新的版本

## 效果

| 能力 | 说明 |
|---|---|
| 开机自启 | 重启后自动拉起，无需手动操作 |
| 崩溃自愈 | 进程被杀自动重启，带退避；每 60 秒健康检查 |
| 一键更新 | `9router update` 在手机上直接升级 9Router，**失败自动回滚**，不重刷模块、不丢数据 |
| 两个界面 | Dashboard `20128`（含 OpenAI 兼容 `/v1`）+ 独立控制面板 `20129` |
| 本机 + 局域网 | 本机直连；局域网设备带 API Key 即可用 |
| 密码不怕忘 | 默认 `123456`，当前密码直接显示在模块详情页与 `9router status` |
| 轻量 | 核心空闲约 90MB（PSS）；控制面板可随时关掉，省约 30MB |

> 仅支持 **arm64-v8a** 设备。

## 安装

1. 用 Magisk / KernelSU / APatch 管理器 App → 模块 → **从本地安装** → 选择 `9router-Magisk-<版本>.zip`
2. 重启手机
3. 打开 Dashboard：`http://<手机IP>:20128/dashboard`，密码 `123456`
   （手机本机访问可把 IP 换成 `127.0.0.1`）
   控制面板：`http://<手机IP>:20129`

## 使用

**在电脑或其他设备上调用 AI**（局域网）

```bash
# 先在手机上生成一个 API Key（远端调用 /v1 必须要）
9router key

# 然后在电脑上：Base URL 与 Key 填进任意 OpenAI 兼容客户端
Base URL : http://<手机IP>:20128/v1
API Key  : sk-xxxxxx
```

**常用命令**（手机终端执行；若提示找不到 `9router`，用完整路径
`/data/adb/modules/ksu_9router/system/bin/9router`）

| 命令 | 作用 |
|---|---|
| `9router status` | 查看版本 / 进程 / 地址 / 当前密码 / API Key |
| `9router start` `stop` `restart` | 启停服务 |
| `9router update` | 更新 9Router 应用（`9router update 0.5.69` 可指定版本） |
| `9router rollback` | 回滚到上一版本 |
| `9router setpw <密码>` | 修改 Dashboard 密码 |
| `9router key` | 生成局域网 API Key |
| `9router lan on\|off` | 开放局域网 / 仅本机 |
| `9router ui on\|off` | 开/关 20129 控制面板（不用时关掉可省约 40MB 内存） |
| `9router log` | 查看日志 |

**更新机制**

- **应用**：`9router update` 在设备内完成，自动校验并支持回滚
- **模块**：管理器模块页会依据本仓库 Release 提示更新，点一下刷入即可（应用数据不受影响）

## 故障排查

服务起不来时，先在手机终端跑一条命令（模块目录即使被清理过也能跑，安装时会在数据区留一份 CLI）：

```bash
9router doctor        # 或 /data/adb/9router/bin/9router doctor
```

它会一次列出：node 运行时（模块自带 + 数据区镜像两份，各自的大小/权限/能否执行）、模块目录与 `versions`、`app` 软链、
`/system/bin/linker64`、系统工具是否齐全、模块管理器痕迹（旧 ID 残留 / `remove` / `disable` / `modules_update`）、
磁盘与日志尾部 —— 直接整段贴回反馈即可定位。

| 现象 | 可能原因 | 处理 |
|---|---|---|
| 日志出现 `runtime/bin/node.bin: No such file or directory` | 模块目录里的运行时文件被管理器"换入/镜像/清理"弄丢（或文件在但已损坏、系统 ELF 解释器不可达） | 服务会自动改用数据区那份运行时镜像（`$DATA/runtime`），无需干预；两份都没了用 `9router repair <刷机包.zip>` |
| 日志连续刷 `核心服务启动失败` / `连续失败 N 次` | 核心进程启动即退出或反复崩溃 | `9router log` 看上方原始报错；应用更新后出问题用 `9router rollback` |
| `9router doctor` 显示 `linker64=缺失` | 系统/挂载层问题，不是模块文件缺失 | 重启一次；仍异常请把 doctor 输出贴回（属于 magisk/KernelSU 挂载层问题） |
| 想省下运行时镜像占的约 88MB | — | 在 `/data/adb/9router/env.sh` 里设 `RUNTIME_MIRROR=0`，再 `rm -rf /data/adb/9router/runtime` |

> 运行时为什么要存两份：`/data/adb/modules/<id>` 由模块管理器管理（安装换入、模块镜像、清理都可能重写它），
> 历史上出现过重启后 `runtime/bin/node.bin` 消失导致服务再也起不来；`/data/adb/9router` 是我们自己的数据区，
> 管理器不碰。开机时两份都会校验，可用者优先，并自动互相补齐。

## 卸载

管理器里移除模块即可（会先停掉守护进程与服务）。
数据默认保留在 `/data/adb/9router`，需要彻底清空就执行 `rm -rf /data/adb/9router`。

## 更多

- 方案、权衡与构建发布流程：[DESIGN.md](./DESIGN.md)
- 第三方组件许可：[module/NOTICE](./module/NOTICE)
