---
name: github-connectivity
description: Diagnose and repair GitHub connectivity failures on Windows (browser cannot open github.com, git clone/pull hangs, raw.githubusercontent.com unreachable) with a five-layer probe — proxy → DNS → TCP → TLS/SNI → browser cache — then pin a verified-live IP into the hosts file, verify it, and roll back safely. Use when the user reports GitHub is unreachable, github.com will not load, clone times out, raw/gist/Pages fail, or an existing hosts workaround (GitHub520 / FastGithub / SwitchHosts) stopped working. 用于 Windows 上诊断并修复 GitHub 连接故障（浏览器打不开 github.com、clone/pull 超时、raw.githubusercontent.com 无法访问）：按"代理→DNS→TCP→TLS/SNI→浏览器缓存"五层逐层排查，把实测可用的 IP 钉入 hosts，再验证与回滚。当用户反馈 GitHub 连不上、github.com 打不开、git clone 卡住、raw/gist/Pages 访问失败，或 GitHub520 之类 hosts 方案失效时使用。
---

# GitHub 连接诊断与修复（Windows）

"GitHub 连不上"是一个**结论**，不是一个**现象**。本 skill 把它拆成可独立验证的五层，
每层给出明确的判定标准，避免把"没装 git"、"浏览器缓存"、"hosts 被第三方改写"
误判成"被墙"。

## 硬性规则

1. **先分层，再动手。** 任何"连不上"必须先跑完 L1~L5，禁止直接改 hosts。
2. **区分 `IP_DEAD` 和 `SNI_BLOCKED`。** 这是本 skill 的核心判据：
   - `IP_DEAD` → 换 IP 有效，hosts 能修；
   - `SNI_BLOCKED` → 换 IP 永远无效，hosts 是徒劳，只能走代理。
   分不清就会反复"改了 hosts 还是打不开"。
3. **`TcpTestSucceeded = True` 不代表可用。** SYN 能被中间盒应答后丢弃，
   必须以完整 TLS + HTTP 请求的结果为准。
4. **改 hosts 前必须备份并记录写入时间**，改完必须复测。
   存在第三方托管块（GitHub520 等）时，要预判它随时会被覆盖。
5. **`ipconfig /flushdns` 只清系统缓存。** 浏览器有自己的 host resolver cache，
   不清它就会出现"curl 通了但浏览器还是打不开"。
6. **Windows PowerShell 5.1 按 GBK 读取脚本文件。** 含中文的 `.ps1`
   必须存成 UTF-8 with BOM 或纯 ASCII，否则报"字符串缺少终止符"。
   诊断脚本一律用英文输出。

## 先排除伪故障

在怀疑网络之前，先确认工具本身存在：

```powershell
Get-Command git
Get-ChildItem "$env:ProgramFiles\Git\cmd\git.exe","$env:LOCALAPPDATA\Programs\Git\cmd\git.exe" -ErrorAction SilentlyContinue
```

> 实战教训：曾出现 `git clone` 失败，排查半天网络，实际是**整机根本没装 git**。

## 诊断流程

首选脚本（自动完成 L1~L4 并给出判定表）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  "$env:USERPROFILE\.config\opencode\skills\github-connectivity\scripts\Test-GitHubConnectivity.ps1" -Mode Diagnose
```

`-Mode Scan` 只扫候选 IP；`-Mode Apply` 扫描并写入最优 IP。

需要手工复核时，按下述顺序执行。

### L1 代理层

```powershell
netsh winhttp show proxy
(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyEnable
git config --global --get https.proxy
```

判据：`ProxyEnable=0` + WinHTTP 显示 `Direct access` → 直连，排除代理干扰。
若配置了代理但进程已死，则所有域名都会失败，需先修代理。

### L2 DNS 层

```powershell
Resolve-DnsName github.com -Type A -DnsOnly
Resolve-DnsName github.com -Type A -DnsOnly -Server 1.1.1.1
```

判据：**同一域名返回多个 IP，且其中有不连通的** → 就是它。
典型污染特征：返回 `46.82.174.68`、`37.61.54.158`、`20.6.7.17` 之类
既不在 GitHub 网段、也连不上的地址。

### L3 TCP 层

```powershell
Test-NetConnection github.com -Port 443 -InformationLevel Detailed
```

只作为参考，不下结论（见硬性规则 3）。

### L4 TLS / SNI 层 —— 关键

用 `curl --resolve` 绕过 DNS，直连指定 IP 并带上**正确的 SNI**：

```powershell
curl.exe -s -o NUL -m 8 --resolve "github.com:443:20.27.177.113" `
  -w "%{http_code}|%{remote_ip}|%{time_total}s" "https://github.com/"
```

**判定表：**

| 结果 | 判定 | 换 IP 有用？ |
|---|---|---|
| `200`，耗时正常 | REACHABLE | — |
| `000`，耗时 **< 2 秒** | SNI_BLOCKED（TLS 被 RST） | ❌ 永远无用 |
| `000`，耗时 **≥ 5 秒** | IP_DEAD（SYN 被丢） | ✅ 有效 |
| `400` / `403` | WRONG_SERVICE（IP 活着但不对应此服务） | — |
| `301` / `302` / `404` | REACHABLE（正常响应） | — |

> `20.205.243.168` 是 API 专用节点，拿它当 `github.com` 会返回 `400`，
> 不要误判成"这个 IP 能用"。

### 兄弟域名对照法

鉴别"IP 被封"还是"域名被封"的最快手段：**拿同一 IP 上的兄弟域名做对照**。

```powershell
# 同一个 IP 185.199.111.133
curl.exe -s -o NUL -m 8 --resolve "raw.githubusercontent.com:443:185.199.111.133" `
  -w "%{http_code}`n" "https://raw.githubusercontent.com/"          # 000，0.23s
curl.exe -s -o NUL -m 8 --resolve "objects.githubusercontent.com:443:185.199.111.133" `
  -w "%{http_code}`n" "https://objects.githubusercontent.com/"      # 404，正常
```

一个通一个不通 → **纯 SNI 封锁**，与 IP 无关。
同理可对照 `github.io` vs `githubstatus.com`（同为 `185.199.108.153`）。

### L5 应用层

用浏览器自己的内核验证，绕开用户配置和缓存：

```powershell
& "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" `
  --headless=new --disable-gpu --no-first-run `
  --user-data-dir="$env:TEMP\edge-test" --dump-dom "https://github.com/" | Select-Object -First 3
```

能 dump 出 HTML → 主机侧已通，剩下的只是**浏览器缓存**。
结束后删除 `$env:TEMP\edge-test`。

## 修复流程

### 1. 扫描并挑选 IP

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  "$env:USERPROFILE\.config\opencode\skills\github-connectivity\scripts\Test-GitHubConnectivity.ps1" -Mode Scan
```

候选池见脚本 `$CandidateIps`。挑 `REACHABLE` + `200` + 耗时最低的，
再连测 3 次确认稳定（脚本会自动做）。**同一 IP 十分钟内可能失效**，
所以"挑最快"要配合"连测 3 次"。

### 2. 写入 hosts

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  "$env:USERPROFILE\.config\opencode\skills\github-connectivity\scripts\Test-GitHubConnectivity.ps1" -Mode Apply
```

脚本行为（需管理员权限）：
1. 备份为 `hosts.bak-yyyyMMdd-HHmmss`；
2. **在原行位置替换** `github.com` 的 IP（不追加到文件末尾，避免重复条目）；
3. 同步补 `www.github.com`；
4. `ipconfig /flushdns`；
5. 连测 4 次验证。

手工操作时注意：`www.github.com` 往往**只**解析到坏 IP，必须单独钉。

### 3. 验证

```powershell
1..4 | ForEach-Object {
    curl.exe -s -o NUL -m 10 -w "http=%{http_code} ip=%{remote_ip} t=%{time_total}s`n" "https://github.com/"
}
```

### 4. 清浏览器缓存

必须**完全退出浏览器**（任务管理器里所有 `msedge.exe` / `chrome.exe`），或：

- `edge://net-internals/#dns` → **Clear host cache**
- `chrome://net-internals/#dns` → **Clear host cache**

## 回滚

```powershell
Get-ChildItem "$env:windir\System32\drivers\etc\hosts.bak-*" | Sort-Object LastWriteTime -Descending
Copy-Item "$env:windir\System32\drivers\etc\hosts.bak-<stamp>" "$env:windir\System32\drivers\etc\hosts" -Force
ipconfig /flushdns
```

## 能力边界

| 域名 | 可修复性 | 原因 |
|---|---|---|
| `github.com` / `www.github.com` | ✅ hosts 可修 | 前端 IP 会失效或污染 |
| `api.github.com` | ✅ 通常正常 | — |
| `codeload.github.com` | ✅ hosts 可修 | 影响 `clone`/下载 tarball |
| `objects./avatars./media./cloud.githubusercontent.com` | ✅ 通常正常 | 头像、Release 附件 |
| `github.githubassets.com` | ✅ 通常正常 | 页面 CSS/JS |
| `raw.githubusercontent.com` | ❌ **hosts 无效** | SNI 封锁 |
| `gist.github.com` | ❌ **hosts 无效** | SNI 封锁 + DNS 污染 |
| `github.io` | ❌ **hosts 无效** | SNI 封锁 |

**结论：hosts 只能救 `github.com` 本身；raw / gist / Pages 必须走代理。**
不要向用户承诺"改了 hosts 就全好了"。

## 第三方 hosts 工具（GitHub520 / FastGithub / SwitchHosts）

这类工具会维护一个托管块：

```
# GitHub520 Host Start
...
# GitHub520 Host End
```

风险：
1. 它给的 IP 是**快照**，可能已失效 —— 实战中就是它把 `github.com`
   钉到一个死 IP 上，导致"打不开"；
2. 它会**覆盖你的修改**，包括块外的追加内容（视工具实现而定）。

因此：

```powershell
(Get-Item "$env:windir\System32\drivers\etc\hosts").LastWriteTime
Get-ScheduledTask | Where-Object { ($_.Actions.Arguments -join ' ') -match 'hosts|github' }
Get-Service | Where-Object { $_.Name -match 'hosts|github|Watt|Clash|Fast' }
```

- 改完后隔一段时间复查 `LastWriteTime`，确认没有被再次改写；
- 若存在活动更新器，**改托管块内部的值**而不是追加块外，或先停掉更新器；
- 用户再次运行该工具后，必须重新跑一次 `-Mode Diagnose`。

## 长期方案

hosts 是补丁，不是方案。出现以下任一情况时，明确建议用户上代理/VPN：

- 候选池里大量 `IP_DEAD`，可用 IP 延迟普遍 > 2 秒；
- 同一 IP 在十分钟内从 200 变成 000（本 skill 实测遇到过）；
- 用户需要 `clone` 大仓库、`pip install git+...`、访问 GitHub Pages。

## 实战踩坑记录

1. **`github.com` 有两个 A 记录，一个好一个死。** 浏览器命中死的就一直转圈；
   `www.github.com` 更可能只解析到死的那个。
2. **hosts 被覆盖。** 修复后 1 小时内被 GitHub520 更新覆盖两次，IP 从
   `20.205.243.166`（死）变成 `57.155.223.240`（活）。**改完必须复测。**
3. **`ipconfig /flushdns` 不够。** 系统层 curl 已 200，浏览器仍打不开，
   因为 9 个 `msedge.exe` 进程缓存着旧 IP。
4. **同 IP 不同域名结论相反。** `raw.githubusercontent.com` 0.23 秒 RST，
   而 `objects.githubusercontent.com` 同 IP 返回 404 —— 说明是 SNI 封锁。
5. **`Test-NetConnection` 误报。** 对死 IP 有时返回 `TcpTestSucceeded=True`。
6. **PowerShell 脚本编码。** 中文 `.ps1` 被按 GBK 解析导致语法错误，
   改用纯 ASCII 后正常。
7. **验证 L5 时不要用 `>` 重定向。** `msedge.exe` 是 GUI 子系统程序，
   `... --dump-dom url > out.txt` 会得到 0 字节（父进程立即返回，输出在
   分离的子进程里）。必须用管道捕获：`& msedge.exe ... --dump-dom url | Select-Object -First 3`，
   此时 `$LASTEXITCODE` 恒为 `-1`，不要用它判断成败，只看有没有 HTML。
8. **候选池会整体塌陷。** 某一时刻 16 个候选 IP 中 14 个 `IP_DEAD`，
   仅剩 2 个可用；其中 `20.26.156.215` 单次探测 200（2.5s）但复测
   **0/3** 全失败。所以必须做 3 次复测，单次采样会选到死 IP。
