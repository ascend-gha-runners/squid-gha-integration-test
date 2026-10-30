# squid 本地/远程与可缓存性分类实施计划

> 状态：提案（待平台侧评审）
> 依据：gy-005 run 37868450910 事故取证（2026-10-09）
> 范围：squid-config CM + runner pod 代理注入。**不含测试套件改动**。

## 〇、事故结论（为什么需要这个计划）

runner pod 复用同一 IP（10.0.0.249）时，squid 保留了上一轮 origin 的
`/health`、`/v1/models` 缓存条目；下一轮 origin 未就绪时 revalidate 失败，
squid 吐出陈旧 200（`TCP_REFRESH_FAIL_OLD_ABORTED`）→ 探活假阳性 →
POST 突发打到未监听端口全灭（ECONNREFUSED × 9）。

事故 = 两个分类同时缺失：
1. **本地流量没被识别为本地**——pod IP 流量被打进了 squid；
2. **"永不缓存"类不存在**——无 Cache-Control 的动态响应被存储，且
   revalidate 失败时服务陈旧副本。

## 一、目标：四象限分类

| | 可缓存 | 不可缓存 |
|---|---|---|
| **远程**（默认路由世界） | A/B 类 refresh_pattern 管辖（现状保留） | 尊重 origin 头 + catch-all 再验证（现状保留） |
| **本地**（非默认路由世界） | ——（不存在此象限） | **永不进 squid 缓存语义**（本计划新增，双层强制） |

**本地/远程唯一判据**：拔掉默认路由还通的 = 本地。
即：pod CIDR、service CIDR、node CIDR、`*.svc.cluster.local`、
`*.cluster.local`、localhost/127.0.0.0/8、link-local。

**缓存语义权威**：origin 响应头（Cache-Control / ETag / Last-Modified）。
squid 的 refresh_pattern 分类学（immutable 年级缓存 / 可变 LM 老化 /
元数据有界 TTL / catch-all 逐次再验证）保持现状，**本计划不动它**。

**明确否决的做法**：用路径关键词猜动态端点（`api/`、`health`、`token` 之类）。
证伪：modelscope 模型下载走 `/api/v1/models/...`（主工作负载会被废掉缓存）；
pypi 存在名为 `api`、`health` 的包（同名路径连坐）。缓存判定按机制
（地址空间 / origin 头），不按关键词。

## 二、变更 1：squid-config CM（服务端策略层）——先上

每集群 CM 追加（proxy_force_reload）：

```
# ── 本地目的地永不缓存（2026-10-09 事故 gy-005 run 37868450910）──
# 目的地在集群本地址空间的请求：不查缓存、不存储。无存储即无陈旧可吐，
# revalidate 失败时诚实报错。对一切客户端生效（含不认 NO_PROXY CIDR 的
# curl 7.81 / python / wget）。
# 语义边界：只影响缓存决策，不改路由——本地流量仍经 squid 转发
# （保持 NetworkPolicy 拓扑兼容与东向可见性）。
acl local_dst dst <POD_CIDR> <SVC_CIDR> <NODE_CIDR>
cache deny local_dst
```

要点：
- **独立生效，不等变更 2**——单此一条即把"缓存对探活撒谎"的问题类
  在服务端锁死，容器层（CANN 镜像 curl 7.81 不认 NO_PROXY CIDR）由它兜底。
- CIDR 逐集群精确填写，**禁止用 10.0.0.0/8 一把梭**：10/8 与未来 VPC
  peering / 内网 artifact 服务重叠时，静默绕行（失缓存）或直连断路。

### CM 注释修正（顺手）

现 catch-all 注释「无 validator（无 Last-Modified/ETag）的响应默认不缓存，
天然直通」与 squid 7.x 实测不符：无 validator 响应**会被存储**（仅是无法
条件再验证），0 0% 0 使其立即 STALE，revalidate 失败时吐旧对象
（access.log 实锤：`TCP_REFRESH_FAIL_OLD_ABORTED`）。注释改为如实描述。

## 三、变更 2：runner pod 代理注入 NO_PROXY（客户端路由层）——后上

每集群 runner set pod 模板 env（与现有 HTTP(S)_PROXY 注入同处）：

```
NO_PROXY=0.0.0.0,localhost,127.0.0.1,.buildkitd,.svc.cluster.local,.cluster.local,<POD_CIDR>,<SVC_CIDR>,<NODE_CIDR>
```

要点：
- 收益：本地流量客户端即绕行（省一跳）；squid mtail 按 domain 聚合的
  counter 去掉 pod IP 高基数污染；mock/模型下载字节不再计成 MISS 干扰
  带宽节省指标。
- **客户端兼容性边界（必须写进注入说明）**：NO_PROXY 的 CIDR 语法
  curl ≥ 7.86（2022-10）才支持。runner 层（Ubuntu 24.04 / curl 8.5.0）生效；
  CANN 容器（ubuntu 22.04 / curl 7.81）、python requests/urllib、wget
  **不认 CIDR，仍会把本地流量发给 squid**——由变更 1 的 cache deny 兜底，
  行为正确但多一跳。
- 依赖：逐集群 CIDR 表（见下节）。有前置检查：确认目标集群无
  "仅放行 pod→squid、默认拒其他东向"的 NetworkPolicy（gy-005 已验证
  全集群零 NetworkPolicy；其余集群上此变更前查一遍）。

### 逐集群 CIDR 表（上线前逐项发现并填写）

| 集群 | pod CIDR | service CIDR | node CIDR | 发现方式 |
|---|---|---|---|---|
| gy-005 | 10.0.0.0/16（实证：全集群 221 pod IP 均落此段；CCE VPC 网络，`spec.podCIDR` 为空） | 10.247.0.0/16（svc clusterIP 样本实证） | 172.22.5.0/24（21 节点观测值，待与 VPC 子网核对） | 见下方发现命令 |
| gy-003 / gy-004 / gy-006 / hk-001 / cn12-001 / mind-third-ci / aiframework | 待查 | 待查 | 待查 | 同下 |

发现命令（其余集群照抄）：

```bash
export KUBECONFIG=~/.kube/<集群>-kubeconfig.yaml
# pod CIDR：实证法（CCE VPC 网络 spec.podCIDR 常为空，以真实 pod IP 分布为准）
kubectl get pods -A -o wide --no-headers | \
  awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print $i}' | \
  awk -F. '{print $1"."$2".0.0/16"}' | sort | uniq -c | sort -rn
# service CIDR：clusterIP 样本
kubectl get svc -A --no-headers | awk '{print $4}' | grep -v None | sort -u | head
# node CIDR：Internal-IP 分布
kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' | sort -u
# 交叉验证：kubeadm 集群可直接查字段
kubectl -n kube-system get cm kubeadm-config -o yaml | grep -iE 'podSubnet|serviceSubnet'
```

> 判据复核：填完后对每个 CIDR 抽验「拔默认路由可达」——不通的条目删掉，
> 那是远程不是本地。

## 四、实施顺序与验证

```
1. squid CM cache deny local_dst   （每集群一行，立即消灭陈旧应答类）
2. CM catch-all 注释修正
3. NO_PROXY 注入（逐集群，跟 CIDR 表走）
4. 测试套件回退 mock 客户端改动（已定）→ gy-005 重测 gate 在 1+3 落地
5. 生产 runner 批量验证（test-squid/test-production-runners.sh 全量）
```

验证判据：

| 层 | 判定 |
|---|---|
| squid 策略（变更 1） | 同一 pod IP 起源站的 `/health` 连发两次，access.log 第二次**不得**出现 `TCP_REFRESH_HIT` / `TCP_REFRESH_FAIL_OLD*`；源站停掉后再请求必须诚实 503（无陈旧 200） |
| 注入路由（变更 2） | runner 层经 pod IP 的请求在 access.log **零新增条目**（客户端已绕行）；`NO_PROXY` env 快照含本集群 CIDR |
| 端到端 | gy-005 vllm 组（model-pull + api-stream）连续 3 轮全绿 |

## 五、风险与回滚

| 风险 | 缓解 |
|---|---|
| CIDR 表漂移（集群扩容改 CIDR） | 注入说明注明 CIDR 来源与复核判据；drift 表现为本地流量多一跳（cache deny 兜底正确性），不致错数据 |
| 未来内网 peering 服务落入本地 CIDR | 逐集群精确 CIDR（非 10/8）使重叠面最小；新增服务走 Service DNS（`.svc` 后缀本就绕行） |
| NetworkPolicy 拓扑差异 | 变更 2 仅在逐集群检查通过后上；变更 1 不改路由，无此风险 |
| 回滚 | 两处变更均为声明式两行配置，删除即回滚；测试套件侧回退独立可逆 |
