# 元测试设计规则（META-TEST）

> 本文件回答一个问题：**什么样的 squid 测试才是有效的测试？**
> 所有 case（见 [CASES.md](./CASES.md)）必须逐条满足这些规则；新增 case 前先对照本文。

## 〇、runner 无关原则

规则只约束**测试逻辑层**（`run-suite.sh` + `cases/`），不约束 harness 层。
runner（GitHub Actions runner / k8s Volcano Job / 本地 docker）只影响三件事：
调度方式、日志获取方式、清理手段。换 runner 不改 case 语义，只换壳。

## 一、被测对象先拆面（测什么）

squid 不是黑盒。每个 case 必须声明自己打哪个功能面：

| 面 | 内容 | 并发测试是否涉及 |
|---|---|---|
| F1 放行/隧道 | 普通 HTTP 代理、CONNECT 隧道、MITM(bump) 证书链 | 是 |
| F2 重写 | url_rewrite 每条规则的命中与落点正确性 | 否（单流已够） |
| F3 缓存 | MISS→HIT 闭环、refresh_pattern、多副本缓存 | **核心** |
| F4 完整性 | MITM/bump 下内容不损坏、不截断、不混源 | **核心** |
| F5 并发承载 | 多流聚合吞吐、缓存踩踏、连接上限、错误率 | **核心** |
| F6 失败面 | 上游 5xx/超时/DNS 失败的透传行为、失败后 squid 是否仍健康 | 是 |

## 二、判定规则（怎么算 PASS）

- **R1 双端证据链**：客户端侧（exit code + 内容签名：magic bytes / JSON 字段 / sha256）
  与 squid 侧（access.log 目标域 / `TCP_MISS`、`TCP_HIT` 状态码，或客户端可见的
  `Via` / `X-Cache-Lookup` 响应头）**两边都对上才算 PASS**。
  只看客户端成功 = 无效判定（流量可能根本没经过 squid）。
- **R2 判定全脚本化**：一切判定可机器执行（正则 / 魔数 / 哈希 / 响应头匹配），
  禁止"人工看日志觉得对"。
- **R3 负样本守卫**：每类判定方法至少配 1 条故意错的（已知输入的失败断言），
  证明判定本身能抓错——否则测试可能恒真。
- **R4 无基线不出数**：一切耗时/吞吐数据必须有对照才有意义：
  直连 vs 经 squid、MISS vs HIT（同 URL 二连发）、1 流 vs N 流。

## 三、隔离与可重复（工程律）

- **R5 case 独立且幂等**：单 case 可单独跑；重跑不依赖上次状态
  （每次 run 唯一 run-id / 临时目录 / 缓存键）。
- **R6 真实 URL + mock 载荷**：保留真实 URL 路径与工具链，只缩载荷；
  大载荷做成显式开关（`HEAVY=1` 压测模式），默认快跑。
- **R7 失败不传染**：阶段级 continue-on-error，所有结果（含失败与跳过）
  写入结构化 TSV，最后统一汇总——失败也是数据。

## 四、并发测试专用规则

- **R8 并发三象限**，必须分开测，不可混为一谈：
  1. **同对象并发**：N 个 worker 拉同一 URL——测缓存踩踏/回源合并，
     验证不产生内容错乱；
  2. **异对象并发**：N 个 worker 拉不同 URL——测回源带宽聚合与连接承载；
  3. **异工具混合并发**：pip + git + wget + curl 同时跑——真实 CI 形态，
     测各协议互不干扰。
- **R9 先正确后性能**：并发判定分两级——第一级正确性
  （0 错误、所有 worker 内容签名一致、无 502/504/截断），
  第二级性能（吞吐随并发度的扩展曲线、p50/p95 时延）。
  正确性不达标，性能数据作废。
- **R10 阶梯加压**：并发度按 `LADDER`（默认 `1 4 8 16`）阶梯递增，
  找拐点/失败阈值，而不是单点打一发。每档都留 timing 记录。

## 五、元验证（test the test）

- **R11 套件自检**：套件必须含"元用例"（`meta-trace` 阶段）证明自己有效——
  **squid 专属痕迹检查**：经代理的响应必须带 `X-Cache-Lookup` 头或 `Via` 含 squid 标识，
  否则判 FAIL（"流量未经过 squid，整套测试无效"）。
  注意不能用任意 `Via`/`X-Cache` 判定——ISP/CDN 缓存也会注入这些头（本地实测
  电信缓存 `via: CHN-...-CACHE` 即假阳性），必须是 squid 专属形态。
  如果关掉/绕开 squid 测试还是全绿，说明测试没打中被测对象。

## 五点五、透明重写维度（源自 no-mirror-test，2026-09-29 增补）

> 背景：gy-006 的 squid 启用了 `url_rewrite_program`（rewrite-helper.sh，squid-config CM），
> 客户端零镜像配置、官方 URL 进，服务端透明重写到镜像站。此前套件完全没测这个维度
> （所有"直连官方域名"的阶段实际已被重写却在盲跑）。

- **R12 no-mirror 公理**：测试脚本零镜像配置——客户端一律官方默认 URL
  （pypi.org / github.com / registry.npmjs.org / repo.openeuler.org …）。
  加速只能来自 squid 服务端 url_rewrite；任何 case 显式写镜像 URL 即违例
  （前车之鉴：tool-hf 曾写死 HF_ENDPOINT=hf-mirror.com，已删；huggingface
  无重写规则，按原套件决策整体排除）。
- **R13 同构性守护**：每条重写规则都用「官方 URL 经 squid → 验证响应内容形态」
  校验（签名判定：JSON 关键字段 / gzip 魔数 1f8b08 / ELF 魔数 7f454c46 /
  `Origin: Ubuntu` / `<repomd`）。镜像路径不同构（404/错内容）→ FAIL。
  GHA runner 不挂 squid-config CM，helper 断言层（tool-17 [A] 层）不可用，
  只做内容签名层（[B] 层）——留档为环境边界。
- **R14 负样本对照**：至少一条故意错误映射（期望 404/403），证明签名判定方法
  本身有效（tool-17 的 NEG-demo 传承）。
- **R15 回归守卫**：已知事故形态作固定断言——`go.dev/dl?mode=json` 必须返回
  JSON 不能是目录页（tool-18 事故）；crates 下载必须走 `rsproxy.cn/api/v1/crates`
  （tool-17 实测修复的旧映射 404）。helper 回退即报警。
- **R16 工具 e2e 零改写移植**：no-mirror-test 的 tool-* 真实工具用例移植到 GHA
  时，只剥环境壳（k8s Job → workflow step），**业务命令零镜像配置原样保留**；
  工具链缺失（runner 无该工具）记 SKIP（数据），工具在而执行失败记 FAIL。
  环境不可行的用例（yum 需 openEuler、buildkit 需服务端）排除并留档。
- **R17 上游通道集中失败判据**（2026-10-08，源自 cn12-001 runbook 诊断）：
  零散上游超时（如 GitHub Actions 构件通道 9/17 次）是出口固有抖动，单次探测
  失败不得判 FAIL；判 FAIL 只看**单域集中失败**（同域 N 次探测 ≥2/3 失败，
  对齐告警降噪口径 `sum by (host) > 3`）。通道健康度带延迟预算（gh-proxy
  p50 > 5s 判 FAIL——test 实例 3.2s 已属不健康）。无法在 CI 时限内观测的
  squid 行为（read_timeout 30min）只做数据留档不判结论。

## 六、与两份前作的关系

| 前作 | 复用什么 | 本套件差异 |
|---|---|---|
| `vllm-benchmarks` wt-test-squid `test-squid/` | mock 载荷原则（R6）、阶段计时 TSV（R7） | 它按"CI 下载/上传链路"组织；本套件按"squid 功能面"组织，新增并发维度 |
| `squid_e2e_tests` no-mirror-test `tool-*.yaml` | 双端证据（access.log 取证）、负样本对照（tool-17）、幂等循环跑批 | 它绑定 gy-006 k8s；本套件核心逻辑 runner 无关，k8s 只是壳之一 |
