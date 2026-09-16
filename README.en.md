<div align="center">

# 9Router Android Module (Magisk / KernelSU / APatch)

**Turn [9Router](https://github.com/decolua/9router) into an always-on AI gateway on your phone.**

[![Release](https://img.shields.io/github/v/release/liisoya/9router-magisk?label=Release&color=blue)](https://github.com/liisoya/9router-magisk/releases/latest)
[![License](https://img.shields.io/github/license/liisoya/9router-magisk?label=License)](./LICENSE)
![Platform](https://img.shields.io/badge/Platform-arm64--v8a-orange)
![Android](https://img.shields.io/badge/Android-7.0%2B-3ddc84)

English | [**中文**](./README.md)

</div>

Install the module and reboot — your phone becomes a 24/7 9Router service. Tools on the phone itself (Termux / CLI) and computers on the same LAN can use it directly, with no desktop machine left running.

---

## Origin

- Service core: [decolua/9router](https://github.com/decolua/9router) (MIT) — **this module uses the official prebuilt artifacts as-is; no source modifications**
- This module: https://github.com/liisoya/9router-magisk
- Started from the approach of [Aydin04/9router-magisk](https://github.com/Aydin04/9router-magisk) (bundled Node + supervisor), then rewritten to be build-free, verifiable and updatable on-device

## What you get

| Capability | Details |
|---|---|
| Auto-start on boot | Starts by itself after reboot, no manual step |
| Self-healing | Restarts automatically when killed (with backoff); health check every 60s |
| One-command update | `9router update` upgrades 9Router on the phone, **auto-rolls back on failure**, no re-flash, no data loss |
| Two interfaces | Dashboard on `20128` (with OpenAI-compatible `/v1`) + standalone control panel on `20129` |
| Phone + LAN | Direct from the phone; LAN devices just need an API Key |
| Password you can't forget | Default `123456`; the current password is shown in the module description and in `9router status` |
| Lightweight | The gateway itself idles at only ~10 MB of RAM |

> **arm64-v8a** devices only.

## Installation

1. Open your Magisk / KernelSU / APatch manager app → Modules → **Install from storage** → pick `9router-Magisk-<version>.zip`
2. Reboot the phone
3. Open the Dashboard: `http://<phone-ip>:20128/dashboard`, password `123456`
   (on the phone itself you can replace the IP with `127.0.0.1`)
   Control panel: `http://<phone-ip>:20129`

## Usage

**Calling the AI from a computer or another device** (LAN)

```bash
# First create an API Key on the phone (required for remote /v1 calls)
9router key

# Then on the computer: put Base URL and Key into any OpenAI-compatible client
Base URL : http://<phone-ip>:20128/v1
API Key  : sk-xxxxxx
```

**Common commands** (run in a terminal on the phone; if `9router` is not found, use the full path
`/data/adb/modules/9router/system/bin/9router`)

| Command | Purpose |
|---|---|
| `9router status` | Show version / processes / addresses / current password / API Key |
| `9router start` `stop` `restart` | Start / stop the service |
| `9router update` | Update the 9Router app (`9router update 0.5.69` for a specific version) |
| `9router rollback` | Roll back to the previous version |
| `9router setpw <password>` | Change the Dashboard password |
| `9router key` | Create a LAN API Key |
| `9router lan on\|off` | Expose to LAN / localhost only |
| `9router log` | Show the service log |

**Update mechanism**

- **App**: `9router update` runs entirely on the device, verifies the download and supports rollback
- **Module**: the manager's module page will offer updates based on this repository's Releases — one tap to flash (app data untouched)

## Uninstall

Remove the module in your manager app (it stops the supervisor and the service first).
Data stays in `/data/adb/9router` by default; run `rm -rf /data/adb/9router` to wipe it.

## More

- Design, trade-offs, build & release flow: [DESIGN.md](./DESIGN.md)
- Third-party component licenses: [module/NOTICE](./module/NOTICE)
