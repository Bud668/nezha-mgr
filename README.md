# nezha-mgr

哪吒监控面板一键管理脚本 | 二进制原生安装 | Nginx 三S优化 | acme.sh 证书 | Telegram 到期推送与健康告警 | 自动更新与一键回退 | 自托管 TG 管理 Bot | Debian/Ubuntu

单文件 Bash 脚本，不依赖 Docker，交互式菜单驱动。面向自建哪吒面板的长期运维：装得起来，更要跑得住、看得见、出事能回退。

---

## ⚡ 一键启动

```bash
command -v curl >/dev/null || { echo "Installing curl..."; apt-get update -qq && apt-get install -y -qq curl; }; curl -fsSL https://raw.githubusercontent.com/Bud668/nezha-mgr/main/nezha-mgr.sh -o nezha-mgr.sh && chmod +x nezha-mgr.sh && ./nezha-mgr.sh
```

需 root 权限运行。后续再次进入菜单：`./nezha-mgr.sh`

---

## 功能总览

| 模块 | 说明 |
| --- | --- |
| 面板安装 | 官方二进制原生安装（非 Docker），自动识别架构，装到 `/opt/nezha` |
| Nginx 配置 | 三S优化（安全/稳定/速度）：HTTP/2、Cloudflare 真实 IP 还原、扫描器 UA 拦截、条件日志、内存缓存模式 |
| SSL 证书 | acme.sh 自动申请与续签，到期前自动 renew |
| GitHub OAuth | 面板登录 OAuth 配置向导 |
| 到期推送 | VPS 到期日 Telegram 推送，消息内嵌「🔄 续期」按钮，点按即可改期 |
| 健康告警 | CPU / 内存 / 磁盘 / 离线 告警，5 秒轮询，离线提醒按递增间隔推送 |
| 自动更新 | 定时检测新版本，自动升级并做健康校验，失败不改动面板 |
| 一键回退 | 升级成功消息附回退按钮，首键永远是「回到升级前版本」 |
| TG 管理 Bot | 自托管 Bot：状态概览 / 设置到期日 / 检查更新，长轮询无需公网回调 |
| 界面美化 | 美化代码已内嵌，一键同步进面板配置 |

---

## 亮点功能详解

### 健康告警：秒级感知，不刷屏

守护进程 `nezha-health.service` 常驻，每 **5 秒**拉取一次面板数据，超过 **15 秒**未上报即判定离线。

告警不是无脑重复推送——持续离线按 **15 / 30 / 45 / 60 / 120 / 300 / 480 / 720 分钟**递增间隔提醒，越久越稀疏，避免一台机器炸出几十条消息。离线与恢复消息都带 CPU / 内存 / 磁盘 / TCP / UDP 现场数据，恢复消息还会标注本次离线总时长。

CPU / 内存 / 磁盘默认阈值均为 **90%**，可在脚本顶部的配置区调整。

### 自动更新：先校验，再切换，随时回退

定时器发现新版本后先下载解压，替换前保留旧二进制；启动后做健康校验，**校验不过就不切换，面板保持原状**并推送失败通知。

升级成功的 Telegram 消息附带回退键盘：**首排永远是「⏮ 回到升级前 <版本>」专属键**——不管当前版本已经往前走了多少个，一键就能回到出问题前的那一版；下方再列最近 3 个官方版本供选择。

### Telegram Bot：最小权限自托管

Bot 用哪吒的 PAT（Personal Access Token）走 REST API，权限按铁律收紧：

- 常驻 token **一律只读**（健康脚本仅 `nezha:inventory:read`）
- 需要写入时用**临时 token，即用即删**，scope 精确到 `service:write`，不带 delete
- `nezha:server:exec` 与 fs 读写删 **任何情况都不授予**——等同全军 RCE
- MCP 保持默认关闭：它为 LLM agent 暴露 exec + 文件读写，叠加 prompt injection 风险，本项目走确定性 REST 即可

另有两道防线：**owner 锁**（第一个 `/start` 的人认领，他人无效）与 **token 异地使用自动吊销**（检测到 `last_used_ip` 非本机立即吊销 token、暂停 bot 并告警）。

Bot 命令：`/start` `/menu` `/server` `/service`

### Nginx：装出来就是加固过的

- **HTTP/2 语法自适应**：检测 nginx 版本，≥1.26 用 `http2 on;`，旧版回落 `listen ... http2`
- **Cloudflare 真实 IP 还原**：内置 CF 官方 IPv4/IPv6 网段，`real_ip_recursive on`
- **扫描器拦截**：nmap / nikto / sqlmap / acunetix 等 UA 直接 403
- **条件日志**：2xx/3xx 不落盘，日志量大幅下降
- **CVE-2026-42533 规避**：生成的配置中 `map` 指令不使用正则匹配（详见 CHANGELOG v1.0.0）

### SQLite WAL 自动收缩

哪吒长期运行后 WAL 文件会持续膨胀（实测可涨到数 GB），引发 `database is locked` 与监控数据丢写。Bot 的每小时循环内会执行 `PRAGMA wal_checkpoint(TRUNCATE)`，在线收缩、不停服务、不新增 systemd 单元。

---

## 菜单结构

```
╔══════════════════════════════════════════════════════╗
║       哪吒监控面板管理脚本  v1.0.0  三S优化版        ║
╠══════════════════════════════════════════════════════╣
║  服务状态                                            ║
║   Nginx / Nezha Dashboard / 到期推送 / 健康告警      ║
║   定时检测 / 自动更新 / SSL 证书                     ║
╠══════════════════════════════════════════════════════╣
║  安装与配置                                          ║
║   1.  安装面板 (Binary + Nginx + Cert)               ║
║   2.  配置到期推送                                   ║
║   3.  配置健康告警 (CPU/内存/磁盘/离线)              ║
║   4.  更新面板 (手动 / 自动更新 / 检测推送)          ║
║   5.  配置 Nginx                                     ║
║   6.  申请/续签证书 (acme.sh)                        ║
║   7.  配置 GitHub OAuth                              ║
╠══════════════════════════════════════════════════════╣
║  服务管理                                            ║
║   8.  查看优化状态                                   ║
║   9.  服务控制 (启动 / 重启 / 停止)                  ║
║   10. 查看实时日志                                   ║
║   11. 同步界面美化代码                               ║
║   12. 配置 TG 管理 Bot                               ║
║   0.  退出                                           ║
╚══════════════════════════════════════════════════════╝
```

菜单顶部实时显示各服务运行状态与面板当前版本，进菜单即可一眼看清全局。

---

## 安装说明

### 系统要求

| 项 | 要求 |
| --- | --- |
| 系统 | Debian / Ubuntu |
| 架构 | `amd64` / `arm64` / `s390x` |
| 权限 | root |

### 自动安装的依赖

`wget` `curl` `socat` `cron` `tar` `unzip` `lsb-release` `gnupg2` `ca-certificates` `openssl` `htop` `nginx` `python3` `python3-bcrypt` `sqlite3`

Python 侧只用标准库 + `python3-bcrypt`，不需要 pip 与虚拟环境。

### 安装后产生的 systemd 单元

| 单元 | 作用 |
| --- | --- |
| `nezha-dashboard.service` | 面板主进程 |
| `nezha-health.service` | 健康告警守护进程 |
| `nezha-notify.service` + `.timer` | VPS 到期推送 |
| `nezha-upgrade.service` + `.timer` | 版本检测与自动更新 |
| `nezha-bot.service` | Telegram 管理 Bot |

主目录 `/opt/nezha`，数据库 `/opt/nezha/data`。

---

## 常见问题

**Q：和 [vps-mgr](https://github.com/Bud668/vps-mgr) 是什么关系？**
A：两者独立。vps-mgr 管的是 VPS 底层（内核、BBR、代理、安全加固），nezha-mgr 只管哪吒面板。新机器建议先跑 vps-mgr 做系统层准备，再用本脚本装面板。

**Q：必须用 Docker 吗？**
A：不用。本脚本走官方二进制原生安装，systemd 托管，省一层容器开销，排障也更直接。

**Q：Telegram 推送需要公网回调地址吗？**
A：不需要。Bot 走 `getUpdates` 长轮询，纯标准库出站请求，不开放任何入站端口。

**Q：自动更新失败会不会把面板搞挂？**
A：不会。升级前保留旧二进制，启动后做健康校验，校验不通过则不切换、面板保持原状并推送失败通知。已经切换成功的也可用消息里的回退按钮一键回到升级前版本。

**Q：Bot 的 token 泄漏了怎么办？**
A：脚本会检测 token 的 `last_used_ip`，一旦发现非本机使用立即自动吊销该 token、暂停 bot 并向 owner 告警。重新生成即可。

**Q：面板数据库越来越大？**
A：WAL 文件由 bot 每小时自动 checkpoint 收缩。主库随 `service_histories` 增长属哪吒自身行为，本脚本不擅自删你的历史数据。

---

## 第三方组件

| 组件 | 用途 | 许可 |
| --- | --- | --- |
| [哪吒监控 nezha](https://github.com/nezhahq/nezha) | 被管理的面板本体 | Apache-2.0 |
| [acme.sh](https://github.com/acmesh-official/acme.sh) | SSL 证书签发与续签 | GPL-3.0 |
| [nginx](https://nginx.org/) | 反向代理 | BSD-2-Clause |
| [MiSans](https://hyperos.mi.com/font/) | 界面美化字体（jsDelivr CDN 引入） | 小米字体许可 |

---

## 免责声明

本脚本会修改系统配置（nginx 配置、systemd 单元、防火墙相关设置）并安装第三方软件。请在理解各操作含义的前提下使用，重要数据请自行备份。

作者不对因使用本脚本导致的任何数据丢失、服务中断或安全事件负责。

---

## License

[MIT](LICENSE)
