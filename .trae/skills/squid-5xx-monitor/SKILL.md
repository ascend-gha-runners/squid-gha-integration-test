---
name: squid-5xx-monitor
description: 跨集群巡检 squid 5xx（mtail squid_requests_total），区分源站 5xx / squid 自造 5xx（超时、转发失败）/ 隧道 5xx，取证 access.log 原始行并产出记录与 issue。Invoke when 用户要看 5xx 突增、MISS_5xx、跨集群代理错误率或 squid 报错。
argument-hint: "[时间窗，如 10m / 1h / 24h / 7d；默认 10m + 24h]"
---

# squid 5xx 跨集群巡检

按固定口径巡检各集群 squid 的 5xx，先定位「哪个集群 × 哪个上游域」，再进集群读
access.log 把 5xx 归因到「源站 5xx / squid 自造 5xx / 隧道 5xx」，最后落记录 + 建 issue。

> 前置：中心 Prometheus `http://113.44.182.82:9090/`（只读）；集群日志需要
> `~/.kube/<cluster>-kubeconfig.yaml`。没有 kubeconfig 时只用 Prometheus 也能完成前 4 步。

---

## 1. 口径（先看，避免误判）

监控查询（用户给的原始 query，**保留 `MISS_5xx|5xx` 两种桶名**）：

```promql
topk(10, sum by (cluster, host) (
  increase(squid_requests_total{job="mtail", cluster=~".+",
    result=~"MISS_5xx|5xx", host!~"squid-cache:.*|-|.*:443"}[10m])
)) > 0
```

- `host!~"squid-cache:.*|-|.*:443"`：排除 mtail 自身抓取、空 host、CONNECT 隧道
  的 `host:443` 形态（隧道的 5xx 单独看 `TCP_TUNNEL/5xx`）。
- **桶名已从 `MISS_5xx` 改为 `5xx`**（ascend-ci-deployment #2556）：新规则是
  **status 唯一入口**——只要客户端最终看到 5xx 就进 `5xx` 桶，**不再看 TAG 族与
  `_TIMEDOUT`/`_ABORTED` 后缀**。所以这个桶天然是混合桶：
  源站 5xx + squid 自造 5xx + 超时 5xx + 取消时带 5xx 的收尾。
- 因此 **5xx 数字大 ≠ 源站故障**，必须进 access.log 按 TAG/status 拆分（见第 4 节）。
- 不要用 `squid_server_http_errors_total` / `squid_server_all_errors_total` 反推：
  实测各集群这两个计数器 24h 增量恒为 0，与 mtail 5xx 并存，不可作为分母/判据。
- 各集群 mtail 规则版本不同：如果 `result="5xx"` 不存在而只有 `MISS_5xx`，
  说明该集群仍是旧规则（旧规则把 `_TIMEDOUT`/`_ABORTED` 排除在 5xx 外），
  结论要按版本说明，不能横向直接比较。

## 2. 五步巡检

### 第 1 步：当前快照（10m / 1h）

```bash
curl -s -G 'http://113.44.182.82:9090/api/v1/query' \
  --data-urlencode 'query=topk(20, sum by (cluster,host) (increase(squid_requests_total{job="mtail", cluster=~".+", result=~"MISS_5xx|5xx", host!~"squid-cache:.*|-|.*:443"}[10m])))' \
| python3 -c 'import sys,json;[print(r["metric"].get("cluster"), r["metric"].get("host"), round(float(r["value"][1]),1)) for r in json.load(sys.stdin)["data"]["result"]]'
```

空结果 = 当前无进行中 5xx，如实记录「无进行中故障」，不要为凑结论放大时间窗。

### 第 2 步：24h / 7d 排行 + 集群汇总

```promql
sum by (cluster) (increase(squid_requests_total{result=~"MISS_5xx|5xx"}[24h]))
sum by (cluster, host) (increase(squid_requests_total{result=~"MISS_5xx|5xx"}[7d]))
```

### 第 3 步：时间分布（判断是否定时/批量）

`query_range`，`step=3600` 跑 7d，只打印 `>=1` 的点：

```promql
sum by (cluster) (increase(squid_requests_total{cluster="<集群>", result=~"MISS_5xx|5xx", host="<域>"}[1h]))
```

- 每天固定时刻（如 01:37/03:37/05:37）→ 定时任务/批量作业；
- 连续数小时 → 上游持续降级；
- 单点尖峰 → CI 一次拉取/一次 job。

时间戳是 UTC epoch，展示时按 CST（+8）标注，避免和 issue 里的时间对不上。

### 第 4 步：进集群读 access.log 归因

```bash
K=~/.kube/sh-002-kubeconfig.yaml
for p in squid-cache-0 squid-cache-1; do
  kubectl --kubeconfig $K -n squid exec $p -c squid -- sh -c "
    grep -hoE 'TCP_[A-Z_]+/5[0-9][0-9] ' /var/log/squid/access.log | sort | uniq -c | sort -rn
    echo '--top-url--'
    grep -E 'TCP_[A-Z_]+/5[0-9][0-9] ' /var/log/squid/access.log \
      | awk '{print \$7}' | sed 's#https\?://##' | cut -d/ -f1 | sort | uniq -c | sort -rn | head"
done
```

native 格式字段：`ts duration client TAG/status bytes method url - HIER/peer mime`
（**url 是第 7 列**，duration 单位毫秒；`HIER_DIRECT/<IP>` 是上游地址，
`HIER_NONE/-` 表示没到上游，如 collapsed forwarding / 本地拒绝）。

再取原始行（含 duration，能直接看出超时阈值）：

```bash
grep -E 'TCP_[A-Z_]+/5[0-9][0-9] ' /var/log/squid/access.log | tail -20
grep -iE 'timeout|timed out|ERROR' /var/log/squid/cache.log | tail -20
```

### 第 5 步：落记录 + 按域名建 issue

记录写入 `SQUID-5XX-MONITORING.md`（本次巡检追加一节，写日期/窗口/证据/结论）。

**一个域名一个 issue**（硬规则）：

1. 先按域名查重：`gh issue list --repo <repo> --search "<域名>" --state all`。
2. 已有该域名的 issue → **在该 issue 下追加评论**补新证据/新集群，不新开。
   同一域名不同原因（如 github.com 的 429 限流与 10s 超时）也归同一个域名 issue，
   用评论区分原因，避免域名碎片化。
3. 无 issue 且 7d 5xx ≥ 10 次 → 新建，**一域一 issue，禁止把多个域名合并**。
4. 7d < 10 次的域名只写进记录文档的「噪声区」，不建 issue（避免脏 backlog）。
5. issue 标题必须带集群与域名，body 用下面的模板。

#### issue 模板

```markdown
## 现象
<集群> 通过 squid 访问 <域名> <路径类型> 出现 5xx：<窗口> 共 N 次，
normal/异常比例、是否自愈、是否仍在发生。

## 证据
- Prometheus：`increase(squid_requests_total{cluster="<集群>", host="<域名>", result=~"MISS_5xx|5xx"}[...])`
  的分布（按小时/按副本），附原始数值。
- access.log 原始行（含 TAG/status、duration、HIER_DIRECT IP）：
  ```text
  ...
  ```

## 归因
按第 3 节判定表写清：源站 5xx / squid 自造（超时、转发失败）/ 隧道 / 折叠转发；
duration 对应哪个超时阈值。

## 影响
哪个 CI/工具链/集群受影响，是否可重试自愈。

## 建议
取证下一步（若日志已轮转，写明下次窗口要抓什么）、治理动作。

---
巡检方法见 `.trae/skills/squid-5xx-monitor/SKILL.md`；桶口径见 ascend-ci-deployment #2556。
```

## 3. 归属判定表（核心）

| access.log TAG/status | 含义 | 归属 |
|---|---|---|
| `TCP_MISS/5xx`（无后缀） | 上游真的回了 5xx | **源站故障**，找服务方 |
| `TCP_MISS_TIMEDOUT/503`、`/504` | 上游读/连接超时，squid 自造 | **网络/上游超时**，看建链 IP 与 duration |
| `TCP_MISS_ABORTED/5xx` | 转发失败（连接拒绝、DNS 失败、连接超时 502 等） | **squid 自造**，不是客户端取消（#2556 源码核对） |
| `TCP_CF_HIT/5xx` | collapsed forwarding 复用了同一个失败结果 | 跟随首个 MISS 的归因，不是独立故障 |
| `TCP_TUNNEL/5xx` | registry splice 隧道失败，无 HTTP 语义 | 单列，不进命中率/错误率分母 |
| `host` 为空 / `-` / `*:443` | mtail 自身抓取、CONNECT 隧道 | 巡检时已排除 |

时长对照：`duration ≈ 9.8~10.3s` → 连接/建链超时（`connect_timeout 10s`）；
`duration ≈ 60~72s` → 读超时（`read_timeout` 量级）；`duration` 很短 + 5xx → 上游直接拒绝/源站 5xx。

## 4. 集群 ↔ kubeconfig

| cluster | kubeconfig |
|---|---|
| aiframework | `~/.kube/aiframework-kubeconfig.yaml` |
| cn12-001 | `~/.kube/ascend-cn12-001-cluster.yaml` |
| hk-001 | `~/.kube/ascend-hk-001-cluster-kubeconfig.yaml` |
| guiyang-001 | `~/.kube/ascend-infra-guiyang-cluster-001-kubeconfig.yaml` |
| guiyang-002 | `~/.kube/ascend-infra-guiyang-ipv6-cluster-002.yaml` |
| guiyang-003/004/005/006 | `~/.kube/openmerlin-guiyang-00{3,4,5,6}-cluster-kubeconfig.yaml`（006 也可用 `~/.kube/gy-006.yaml`） |
| mind-third-ci | `~/.kube/ascend-mind-third-ci.yaml` |
| wlcb-001 | `~/.kube/ascend-infra-wlcb-cluster-001.yaml` |
| sh-001 | `~/.kube/openmerlin-sh-001-cluster-kubeconfig.yaml` |
| sh-002 | `~/.kube/sh-002-kubeconfig.yaml` |

namespace 统一 `squid`，两个副本 `squid-cache-0/1`，squid 容器名 `squid`。

## 5. 坑

1. **access.log 轮转很快**：cn12-001 约 9MB/43min 就滚掉，历史 5xx 只能靠 Prometheus
   还原；要日志证据必须趁窗口还在（先跑第 1~3 步锁定时间，再立刻进集群）。
2. **两个副本都要查**：5xx 可能只落在其中一个（sh-002 就是 cache-0 75 / cache-1 72 不均衡）。
3. **host 标签不是完整 URL**：`host` 是 authority，同一域下不同路径可能是完全不同原因
   （如 github.com 的 `/tree/<ref>/` HTML 页 vs `/zipball`），必须看 url 列。
4. **mtail 规则靠 checksum 滚动生效**：改完 CM 必须重启 statefulset，否则查到的还是旧口径。
5. **`squid_up` 每集群 2 个副本**属正常；sh-001 只有 1 个也正常。
6. **不要用 `client_http_errors_total` 判 5xx**：它没有 code 标签，混了 4xx/abort/5xx。

## 6. 一键采集（只读 Prometheus）

```bash
bash .trae/skills/squid-5xx-monitor/scripts/collect-5xx.sh              # 10m + 24h
bash .trae/skills/squid-5xx-monitor/scripts/collect-5xx.sh --window 1h --trend 7d
PROM_URL=http://113.44.182.82:9090 bash .../collect-5xx.sh             # 换 Prometheus
```

输出可直接贴进记录文档；脚本只做查询，不写任何集群资源。
