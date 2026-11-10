# squid 5xx 跨集群巡检记录

巡检方法见 `.trae/skills/squid-5xx-monitor/SKILL.md`；本文只记录每次巡检的**事实与归因**，
一个域名对应一个 issue（阈值：7d 5xx ≥ 10 次）。

数据源：中心 Prometheus `http://113.44.182.82:9090/`；日志取各集群 `squid/squid-cache-{0,1}`
容器的 `/var/log/squid/access.log`。

---

## 口径提醒：`5xx` 是混合桶

查询：

```promql
topk(10, sum by (cluster, host) (
  increase(squid_requests_total{job="mtail", cluster=~".+",
    result=~"MISS_5xx|5xx", host!~"squid-cache:.*|-|.*:443"}[10m])
)) > 0
```

自 ascend-ci-deployment #2556 起，桶名 `MISS_5xx` 改为 `5xx`，且判定改为 **status 唯一入口**：
只要客户端最终看到 5xx 就进桶，不再看 TAG 族与 `_TIMEDOUT` / `_ABORTED` 后缀。因此该桶里
同时包含：

- 源站真的返回 5xx（`TCP_MISS/5xx`，无后缀）；
- squid 因上游超时/转发失败自造的 5xx（`TCP_MISS_TIMEDOUT/5xx`、`TCP_MISS_ABORTED/5xx`）；
- collapsed forwarding 复用失败结果（`TCP_CF_HIT/5xx`）、registry 隧道失败（`TCP_TUNNEL/5xx`）。

**数字大不等于源站故障**，必须回 access.log 看 TAG/status + duration。

---

## 2026-11-10 基线

采集时间 2026-11-10 14:44 CST。快照窗口 10m：仅 `guiyang-001 / apig.openlibing.com`
仍在发生（25.5 次/10m），其余域名均为 0。

### 7d 排行（按域名）

| 域名 | 7d 5xx | 24h 5xx | 主要集群 |
|---|---:|---:|---|
| apig.openlibing.com | 1498 | 226 | guiyang-001 |
| huggingface.co | 1028 | 1028 | sh-002 804 / aiframework 178 / cn12-001 37 / mind-third-ci 9 |
| datasets-server.hf-mirror.com | 798 | 798 | cn12-001 789 / hk-001 9 |
| gh-proxy.test.osinfra.cn | 656 | 20 | cn12-001 274 / guiyang-006 251 / guiyang-004 104 / guiyang-001 27 |
| github.com | 371 | 234 | hk-001 218 / cn12-001 78 / sh-002 75 |
| registry.npmmirror.com | 126 | 126 | guiyang-002 |
| mirrors.qlu.edu.cn | 100 | 0 | cn12-001 65 / guiyang-001 34 / guiyang-005 1 |
| pypi.douban.com | 17 | 17 | guiyang-001 |
| ascend-ci-cache-hk.obs.ap-southeast-1.myhuaweicloud.com | 17 | 17 | wlcb-001 |
| download.pytorch.org | 13 | 0 | hk-001 9 / guiyang-001 4 |

噪声区（7d < 10，不建 issue）：`[2001:db8::8]:8000` 25（guiyang-001 mock origin 联调用例）、
`www.modelscope.cn` 8、`hf-mirror.com` 4、`files.pythonhosted.org` 2、`archive.ubuntu.com` 1。

### 逐域名归因

#### apig.openlibing.com（guiyang-001，源站 5xx，进行中）

- Prometheus：7d 1498，集中在每天 01:37 / 03:37 / 05:37 CST 三批，11-09 11:37 另有 92 次；
  11-10 14:30 起再次出现，14:43 的 10m 窗口 26 次。
- access.log（cache-0，今日窗口）：

  ```text
  1794292944.317    106 172.16.0.132 TCP_MISS/500 518 POST https://apig.openlibing.com/openlibing-sbom/sbom-api/addProduct - HIER_DIRECT/139.9.154.34 text/plain
  1794292946.431     63 172.16.0.65  TCP_MISS/500 519 POST https://apig.openlibing.com/openlibing-sbom/sbom-api/addProduct - HIER_DIRECT/139.9.154.34 text/plain
  1794292957.149     15 172.16.0.132 TCP_MISS/500 509 POST https://apig.openlibing.com/openlibing-sbom/sbom-api/addProduct - HIER_DIRECT/139.9.154.34 text/plain
  ```

- 归因：**源站返回 500**（无 TAG 后缀、响应 15~106ms），不是 squid 自造。同一域名
  `publishSbomFile` 正常返回 202，仅 `addProduct` 接口 500。上游 `139.9.154.34`（华为云 APIG）。

#### huggingface.co（sh-002 / aiframework / cn12-001，上游超时）

- Prometheus：7d 1028，全部落在 11-09 19:42 ~ 11-10 13:42；sh-002 峰值 224/h（13:42）。
- access.log：

  ```text
  1794288848.668   9916 192.168.211.215 TCP_MISS_TIMEDOUT/503 354 HEAD https://huggingface.co/allenai/longformer-base-4096/resolve/main/config.json - HIER_DIRECT/199.16.156.39 text/html
  1794288874.770     56 192.168.211.215 TCP_MISS_ABORTED/503  354 HEAD https://huggingface.co/allenai/longformer-base-4096/resolve/main/config.json - HIER_DIRECT/157.240.21.9 text/html
  ```

  cn12-001：`TCP_MISS_TIMEDOUT/503` 10047ms `GET https://huggingface.co/` → `HIER_DIRECT/104.244.43.228`。

- 归因：**上游建链/读超时**（≈10s，正好是 `connect_timeout 10s`；个别 56ms 的
  `_ABORTED/503` 是转发失败快速返回）。同一 URL 的 HEAD 请求反复重试，说明客户端在重试。

#### datasets-server.hf-mirror.com（cn12-001，转发失败）

- Prometheus：7d 798，11-09 20:42 ~ 11-10 03:42 持续 8 小时，02:42 峰值 275/h；11-10 14:42 仅 1 次。
- access.log（cn12-001 cache-0）：

  ```text
  1794292075.146   369 10.0.4.98 TCP_MISS_ABORTED/503 2080 GET https://datasets-server.hf-mirror.com/ - HIER_NONE/- text/html
  1794292368.359  2291 10.0.4.98 TCP_MISS_ABORTED/503 2080 GET https://datasets-server.hf-mirror.com/ - HIER_NONE/- text/html
  ```

- 归因：`_ABORTED/503` + `HIER_NONE/-`，**请求没到上游**（DNS/连接失败类转发错误），
  由 squid 自造 5xx。持续 8 小时更像某个 CI 在循环重试放大。

#### github.com（hk-001 / sh-002 / cn12-001，已有 issue）

- 7d 371：hk-001 218、cn12-001 78、sh-002 75。
- hk-001：上游 429 限流（issue #11）。
- sh-002：`/tree/<ref>/` HTML 页直连 `20.205.243.166` 10s 建链超时（issue #15）。
- cn12-001：日志已轮转（9MB/43min），仅有指标，缺原始行，暂不单开。

#### gh-proxy.test.osinfra.cn（多集群，已有 issue）

- 7d 656：cn12-001 274、guiyang-006 251、guiyang-004 104、guiyang-001 27；24h 已降到 20。
- 已有 issue #12（gy-001/gy-005 release 资产 504），本域归该 issue 跟踪。

#### registry.npmmirror.com（guiyang-002，已有 issue）

- 7d 126；`TCP_MISS/504` duration 72000ms、`TCP_CF_HIT/504`，tarball 302 接口 TTFB 超时（issue #13）。

#### mirrors.qlu.edu.cn（cn12-001 / guiyang-001 / guiyang-005）

- 7d 100：cn12-001 65、guiyang-001 34、guiyang-005 1；24h 已归零。
- access.log（gy-002）：

  ```text
  1794282642.206   9326 10.0.2.120 TCP_MISS_TIMEDOUT/503 1879 GET https://mirrors.qlu.edu.cn/epel/8/Everything/aarch64/repodata/....xml.xz - HIER_DIRECT/210.44.151.62 text/html
  1794282652.211   9999 10.0.2.120 TCP_MISS_TIMEDOUT/503 1882 GET http://mirrors.qlu.edu.cn/epel/8/Everything/aarch64/repodata/....xml.xz - HIER_DIRECT/210.44.151.62 text/html
  ```

- 归因：dnf/yum 拉取 epel repodata 时上游 210.44.151.62 超时（≈9.3~10s），squid 自造 503。

#### pypi.douban.com（guiyang-001，转发失败）

- 7d 17，集中在 11-09 22:42 一个窗口。
- access.log（cn12-001）：`TCP_MISS_ABORTED/502` 755ms `GET https://pypi.douban.com/` → `HIER_DIRECT/120.53.130.158`。
- 归因：连接失败（502 自造），非源站 5xx。

#### ascend-ci-cache-hk.obs... / download.pytorch.org（证据有限）

- wlcb-001 的 OBS 缓存域 7d 17 次、hk-001/guiyang-001 的 download.pytorch.org 7d 13 次。
- 两者日志均已轮转，仅有 Prometheus 计数；issue 里标注「待下一次窗口抓 access.log」。

---

## 2026-11-10 aiframework 面板错误率排查（非 5xx）

面板口径 `(ABORT+TIMEDOUT+OTHER+5xx)/全部` 在 aiframework 上把 pip/dnf 探测行为放大：

| 域名 | 面板错误率（5m） | 24h result 拆解 | 结论 |
|---|---:|---|---|
| download.pytorch.org | 28.2% | MISS 41115 / ABORT 19826 / HIT 9719 / REVAL 1729，**无 5xx 无 TIMEDOUT** | 客户端探测 |
| mirrors.huaweicloud.com | 11.0% | MISS_404 119933 / ABORT 14153 / MISS 2791 / HIT 2312 | 客户端探测 + 404 |
| repo.huaweicloud.com | 0.0% | HIT 227133 / MISS 121497 / REVAL 58295 / MISS_404 5736 / ABORT 143 | 健康 |
| www.modelscope.cn | nan（24h ABORT 仅 8） | MISS 1434 / MISS_404 26 / ABORT 8 | 面板噪声 |

access.log 证据（aiframework，窗口 1794272059~1794295189，约 6.4h，cache-0）：

```text
4685 TCP_MISS/403          paths = /whl/cpu/<pkg>/（attrs、typer、fastapi、xgrammar…）
2295 TCP_MISS_ABORTED/403  同一批路径，客户端拿到 403 后断开
 568 TCP_CF_MISS/403       collapsed forwarding 复用 403
 928 TCP_MEM_HIT/200 + 244 TCP_REFRESH_UNMODIFIED/200 + 88 TCP_HIT/200（真实 wheel/metadata）
```

- download.pytorch.org 的 403 由上游 `HIER_DIRECT/52.85.128.85`（CloudFront）返回，body 为
  706~711B `application/xml`（AccessDenied）：pip 配了 `--extra-index-url .../whl/cpu` 后会把
  **所有依赖**都去 torch 源探测，源上不存在的包回 403 而非 404。
- mirrors.huaweicloud.com 的 15k+/副本是 `/ascend/repos/pypi/nightly/<pkg>/` 的 404，
  其中 1.9k 被客户端断开记为 `TCP_MISS_ABORTED/404` → 进入 ABORT → 面板错误率分子。
- `MISS_404` 按设计不进错误率分母，但 `_ABORTED/404` 会进 ABORT，这是面板抬高的直接原因，
  不是 squid/缓存故障。

建议：pip 只在装 torch 时用 `--index-url https://download.pytorch.org/whl/cpu`，其余依赖走内部源，
不要全局 `extra-index-url`；面板侧把 ABORT 拆分或从错误分子移除（与 #2556 后续一致）。

---

## 与既有 issue 的对应

| 域名 | issue | 处理 |
|---|---|---|
| github.com | #11（hk-001 429）、#15（sh-002 10s 超时） | 已有；#15 已追加 cn12-001 证据评论 |
| gh-proxy.test.osinfra.cn | #12 | 已有；已追加 7d 跨集群分布评论 |
| registry.npmmirror.com | #13 | 已有 |
| apig.openlibing.com | #16 | 新建；源站 500，进行中 |
| huggingface.co | #18 | 新建；上游超时 |
| datasets-server.hf-mirror.com | #17 | 新建；转发失败 |
| mirrors.qlu.edu.cn | #19 | 新建；epel repodata 超时 |
| pypi.douban.com | #20 | 新建；连接失败 |
| ascend-ci-cache-hk.obs... | #21 | 新建；证据待补 |
| download.pytorch.org | #22 | 新建；证据待补 |

桶口径改造见 ascend-ci-deployment #2556；本次巡检未发现需要改 mtail 规则的新问题。
