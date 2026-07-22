# 更新日志

本项目版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

---

## [1.1.1] - 2026-07-22

### 变更

- **全新安装默认启用 TSDB（服务监控历史时序库），保留 30 天**

  面板 v2.3.0 起支持 TSDB，但 `tsdb.data_path` 为空时处于禁用状态，服务监控历史会全部写入 SQLite 的 `service_histories` 表 —— 而该表**没有任何清理机制**（面板的 `CleanMonitorHistory` 每天 3:30 只清理流量表 `transfers`）。

  实测某面板 31 个服务监控 × 23 台机器、30 秒间隔运行 52 天，该表累积 **4418 万行**，连同两个索引占用 **8.5 GB**，且按约 200 MB/天持续增长，一年将超过 70 GB。

  安装流程中新增 `set_tsdb`，在 `add_default_monitors` **之前**执行 —— 监控一旦创建就开始产生历史，先开 TSDB 可避免数据落进 SQLite。写入路径在面板代码中是二选一的：

  ```go
  if TSDBEnabled() {
      TSDBShared.WriteServiceMetrics(...)      // TSDB，按 retention_days 滚动
  } else {
      DB.Create(&model.ServiceHistory{...})    // SQLite，无清理
  }
  ```

  **数据保护**：面板首次启用 TSDB 时会 `DROP TABLE service_histories` 且不迁移历史数据。因此 `set_tsdb` 在写入配置前会检查该表行数，若已有历史则打印提示并要求确认，不会静默删除。若 `tsdb.data_path` 已配置则直接跳过。

  配置写入兼容三种情形：首启生成的 `tsdb: {}`、已展开的缩进块、以及键完全缺失；替换正则要求后续行带缩进，因此不会影响相邻的顶层键或前置的 `custom_code: |` 多行块。

---

## [1.1.0] - 2026-07-22

新增 Agent 加固巡检，并将全部推送迁移到 Telegram 话题群 —— 一个群即可承载所有通知，各通道互不干扰。

### 新增

- **Agent 加固巡检（菜单 15）**

  探测各 agent 的 `disable_command_execute` 与 `disable_nat`，发现未加固机器时推送 Telegram 提醒。默认每天 09:30 由 systemd timer 触发，也可在菜单里立即巡检。

  探测原理：`GET /api/v1/server/config/{id}` 会向 agent 下发 `ReportConfig` 任务。未加固的 agent 返回完整配置，可读到两个开关的真实值；已设 `disable_command_execute=true` 的 agent 连回报配置都拒绝，接口返回 `此 Agent 已禁止命令执行` —— 这个拒绝本身即「已加固」的证据。

  几个关键设计：

  - **离线机器一律跳过**。面板的 `ConfigCache` 会把上一次的配置直接返回，对离线机器拿到的是快照而非实时值，据此告警等于凭空捏造。因此先用 `last_active` 过滤，超过 `OFFLINE_SECS` 或为零值的直接跳过
  - **仅在未加固名单变化时推送**，避免同一批机器天天刷屏
  - **复用 bot 已有的 PAT**（`nezha:inventory:read,nezha:server:write,nezha:service:write`），不新增任何常驻凭据
  - 配置接口返回体含 `client_secret` 等凭据，代码只提取两个布尔量，其余不留存、不外发、不写日志

  **能力边界**：只能查出「`disable_command_execute` 未关」的机器。已加固机器的 `disable_nat` 无法远程读取（回报配置被同一个开关挡住），需要 SSH 或重装时经菜单 13 的命令补上。

- **Telegram 话题群支持（菜单 14）**

  健康告警、到期提醒、面板升级、Agent 巡检四个推送通道各自新增 `TG_THREAD_ID`，发送时带上 `message_thread_id`；留空则退回普通群行为，不影响未使用话题的用户。

  菜单 14 统一写入群 Chat ID 与四个话题 ID，写完**逐通道发送一条验证消息**，当场暴露话题 ID 填错或 bot 权限不足，不必等到对应服务真触发才发现。

  TG 管理 Bot 采用另一种方式：回复时原样带回收到的 `message_thread_id`，消息自动落在用户说话的那个话题里，无需配置。

### 变更

- 日志轮转配置新增 `/var/log/nezha_audit.log`

---

## [1.0.4] - 2026-07-22

面向「纯监控」场景的加固：面板只用于看状态，不需要网页终端、文件管理与 NAT 穿透。

### 变更

- **Nginx 屏蔽网页终端与文件管理的全部入口**

  原配置只拦了 `^/api/v1/ws/terminal` 一条。实测发现两处缺口：

  1. 终端的**创建会话**接口 `POST /api/v1/terminal` 未拦（只拦 websocket 时该接口仍可调用）
  2. 文件管理器**完全放行** —— `POST /api/v1/file` 与 `GET /api/v1/ws/file/:id` 均可用，且 WebSocket 白名单 `^/api/v1/ws/(server|file)` 明确将 `file` 列入允许。文件管理器可读写删任意文件，与终端属同级风险

  现按面板 v2.3.0 `cmd/dashboard/controller/controller.go` 的实际注册路由，将四条全部返回 403，并将 WebSocket 白名单收窄为 `server`：

  | 功能 | 创建会话 | WebSocket |
  | --- | --- | --- |
  | 终端 | `POST /api/v1/terminal` | `GET /api/v1/ws/terminal/:id` |
  | 文件管理 | `POST /api/v1/file` | `GET /api/v1/ws/file/:id` |

  该屏蔽与服务器数量无关，新增机器自动生效，无需逐台配置。

- **新增菜单 13：生成 Agent 安装命令**

  从面板配置读取 `install_host`、`tls` 与 `users.agent_secret`，生成新增服务器用的安装命令，并默认追加两个加固开关：

  - `disable_command_execute: true` —— 关闭网页终端、文件管理、命令执行、文件传输与 MCP 处理器
  - `disable_nat: true` —— 关闭 NAT 穿透。这是**独立开关**，`disable_command_execute` 管不到（见 agent v2.3.0 `cmd/agent/nat_session.go`），此前容易遗漏

### 已知边界

Nginx 层只能拦住 HTTP 入口，以下两项需在 agent 侧或面板内解决，已在菜单 13 的提示中说明：

- **NAT 穿透**：隧道任务经 gRPC 下发，不走被拦的 HTTP 路由，Nginx 拦不住，只能靠 agent 的 `disable_nat`
- **DDNS**：为面板内部功能，执行不经 HTTP 接口；不配置 DDNS 配置文件即不会生效

另需注意，`disable_command_execute` 置为 `true` 后，面板下发的 agent 配置修改同样会被拒绝，之后调整该机器的 agent 配置只能通过 SSH。

---

## [1.0.3] - 2026-07-22

### 变更

- 移除 `/etc/logrotate.d/nezha` 中冗余的 `daily`。该指令与 `size 20M` 同时存在时会被后者覆盖（logrotate 运行时提示 `'size' overrides previously specified 'daily'`），实际行为始终是「由 logrotate.timer 每天检查、超过 20 MB 才轮转」。删除后行为不变，仅消除误导与提示。

---

## [1.0.2] - 2026-07-22

对 `1.0.1` 的补强。上线后排查面板机日志时发现，历史上 73 次告警发送失败**全部**是 Telegram 429 限流（集中在 4 天，每次一批 16–20 条），而非偶发超时 —— `1.0.1` 的重试策略在这一真实失败模式下会适得其反。

### 修复

- **遵守 Telegram 429 限流的 `retry_after`**

  `1.0.1` 让发送失败的机器回滚状态、下一轮重发，解决了告警被永久吞掉的问题。但批量掉线时撞上群组限流（约 20 条/分钟）后，该策略会按轮询间隔（默认 5 秒）不断重发整批，只会持续延长限流。

  改为：`send_tg()` 捕获 `HTTPError 429`，从响应体的 `parameters.retry_after` 取出建议等待秒数；发送失败后设置全局静默截止时刻 `_tg_pause_until`，退避期内不再发起任何请求，直接回滚状态等下一轮。非 429 的失败按 `TG_FAIL_BACKOFF`（默认 30 秒）退避。

### 变更

- **新增日志轮转配置 `/etc/logrotate.d/nezha`**

  健康守护进程每 `CHECK_INTERVAL` 秒写一行心跳，此前无轮转配置，实测两个月累积 40 MB / 89 万行且无上限。现随健康服务一并部署，覆盖 `nezha_health` / `nezha_notify` / `nezha_bot` / `nezha_upgrade` 四个日志，按天检查、超过 20 MB 轮转、保留 7 份压缩。

  因各服务使用 `StandardOutput=append:` 持有文件描述符，配置使用 `copytruncate`，轮转无需重启服务。

---

## [1.0.1] - 2026-07-22

修复哪吒面板升级到 v2.3.0 后，服务器掉线不再推送 Telegram 通知的问题。

### 修复

- **适配面板 v2.3.0 的 `last_active` 清零行为（掉线通知失效的根因）**

  v2.2.10 及更早版本，agent 断连后 `/api/v1/server` 仍返回最后一次心跳时间；v2.3.0 起改为立即重置为 Go 零值 `0001-01-01T00:00:00Z`。

  健康告警脚本原有一句 `if not last_act: continue`，本意是躲开「面板重启后全体归零」导致的全员误报，但在新行为下会把**真正掉线的机器整个跳过**，离线、恢复、持续离线提醒全部静默。实测某面板升级后 8 小时内 23 台机器共 70+ 次 agent 断连，仅推送出 1 条告警；一台已离线 1 小时 42 分钟的机器 `offline_reminder_idx` 仍为 `0`，4 条「仍未恢复」提醒全部丢失。

  修复方式：零值本身无法区分「本机掉线」与「面板刚重启」，改为按范围判定 —— 面板重启的特征是 API 刚从不可用恢复（记录 `_last_api_fail`）或本轮全员归零，此时整轮跳过；其余零值一律视为该机器真实掉线，回退到状态文件中记录的 `last_seen` 后照常执行 `OFFLINE_SECS` 判定，检测灵敏度不受影响。

  > 注：未采用「零值持续 N 秒才算掉线」的宽限期方案，那会把配置的 15 秒离线检测拖慢到 N 秒。

- **告警发送失败不再被永久吞掉**

  原先 `save_state()` 在 `send_tg()` 之前执行，Telegram 接口超时或限流时状态已翻转、消息却没发出去，该条告警永久丢失。改为先发送后落盘，发送失败的机器回滚其状态，下一轮重新判定并重发。

- **「开启/关闭离线告警」菜单项此前完全无效**

  该菜单的 `grep -q` 与两条 `sed` 使用 `OFFLINE_ALERT_ENABLED = True`（单空格），而脚本模板中该行为三空格对齐，导致匹配全部落空 —— 菜单每次都打印「已开启」但从未真正改动过配置。同一处空格不匹配也使得重新配置阈值时无法保留用户原有的关闭状态。三处统一改为与模板一致的对齐写法。

---

## [1.0.0] - 2026-07-20

首次公开发布。此前为自用版本，本次整理后开源，版本号从 `1.0.0` 重新计数。

### 安全修复

- **规避 CVE-2026-42533（CVSS 9.2，nginx map 正则匹配堆缓冲区溢出）**

  脚本生成的 nginx 配置原先包含两处正则 `map`，命中该漏洞的触发条件，其中 `map $http_user_agent $bad_ua` 直接对客户端可控的 User-Agent 跑正则。受影响的 nginx 上游版本为 `0.9.6`–`1.31.2`，覆盖当前各主流发行版在用版本，且 Debian 截至 `1.26.3-3+deb13u7` 仍未提供补丁。

  修复方式（功能完全等价，不削弱防护）：
  - `map $status $loggable` 的 `~^[23]` 改为列举 2xx/3xx 状态码，`map` 内不再使用正则
  - `map $http_user_agent $bad_ua` 整块移除，扫描器 UA 拦截改为 server 块内 `if ($http_user_agent ~* "...")`，将正则移出 `ngx_http_map_module`

  修复后生成的配置中，所有 `map` 指令均不含正则匹配。

  > 参考：[NVD CVE-2026-42533](https://nvd.nist.gov/vuln/detail/CVE-2026-42533) ｜ [F5 K000162097](https://my.f5.com/manage/s/article/K000162097)

### 修复

- `[ "$TOKEN" = "请填写" -o -z "$TOKEN" ]` 使用了行为未定义、POSIX 已废弃的 `-o` 操作符，改为 `[ ... ] || [ ... ]`（2 处）
- nginx 配置备份路径 `nginx.conf.bak.$(date +%F_%T)` 未加引号，存在 word splitting 风险

### 变更

- **版本号收敛为单一来源**：新增 `SCRIPT_VERSION` 变量，原先散落在文件头、Nginx 模块注释、配置 banner、菜单标题等 6 处的硬编码版本号统一改为引用该变量，发版时只需改一行
- 文件头注释移除硬编码版本号与失效的「优化日期」

### 已知事项

以下为 shellcheck 提示但**本次未改动**的项，均不影响功能，记录备查：

- `read` 未使用 `-r`（28 处，影响是输入中的反斜杠会被转义吞掉）
- 1 处以 `$?` 间接判断退出码，1 处 `tr 'A-Z' 'a-z'` 建议改用 `[:upper:]`/`[:lower:]` 字符类
- 下载与解压环节有 1 处变量未加引号
- 生成的 nginx 配置 banner 中写有「Debian 12 版」字样，与实际运行环境无关，仅为注释文本

---

<!--
发版流程备忘：
1. 改 nezha-mgr.sh 顶部 SCRIPT_VERSION
2. 在本文件顶部新增版本段落
3. git tag -a v<版本> -m "..." && git push --tags
4. 在 GitHub Releases 粘贴对应段落作为 release notes
-->
