# 更新日志

本项目版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

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
