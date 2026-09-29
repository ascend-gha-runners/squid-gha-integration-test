# 场景设计（function / concurrency 两组）

> 按 [META.md](./META.md) 元规则推导的场景矩阵。
> 每个场景：独立阶段、失败不传染（R7）、结果写 TSV（R2/R7）。

## 通用约定

实现为 **GitHub workflow + 单脚本**（runner = squid 注入的 GHA runner）：

```
.github/workflows/test-squid.yaml   # 入口：workflow_dispatch + pull_request
test-squid/run-suite.sh             # 全部场景逻辑（run_timed 阶段计时 + TSV）
```

workflow 两个 job 调同一脚本：`--mode function`（功能组）与 `--mode concurrency`（并发组），
summary job 拉回 artifacts 输出汇总表。所有场景通过 run-suite.sh 的阶段函数实现，
不拆独立 case 脚本。

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `RESULTS_DIR` | `/tmp/test-squid-results` | 结果目录 |
| `LADDER` | `"1 4 8 16"` | 并发度阶梯（R10），dispatch input 可调 |
| `URL_SMALL` | ubuntu-ports noble `Release`（~200KB，稳定） | 小载荷（R6） |
| `URL_MED` | noble main arm64 `Packages.gz`（~1–2MB） | 中载荷（缓存/完整性/并发主载荷） |
| `URL_HEAVY` | files.pythonhosted torch 2.10.0 aarch64 wheel（~146MB） | 大载荷，仅 `HEAVY=1` 启用（R6） |
| `DOMAINS` | github/pypi/pytorch/huaweicloud 等 | 功能探测域名矩阵 |
| `HEAVY` | `0` | 大载荷压测模式开关（R6） |

判定输出统一 TSV：`phase<TAB>seconds<TAB>status<TAB>group`，
summary job 汇总进 GITHUB_STEP_SUMMARY，artifact 一并上传。

## 场景矩阵（run-suite.sh 阶段 ↔ 元规则）

| 阶段（function 组） | 面 | 场景 | 判定 | 规则 |
|---|---|---|---|---|
| `env-snapshot` | — | 代理注入环境快照（只读） | 留档 | R1 |
| `meta-trace` | — | **squid 专属痕迹检查**：响应必须带 `X-Cache-Lookup` 或 `Via` 含 squid 标识，否则整套测试无效（流量没走 squid；ISP 缓存的 Via 属假阳性） | squid 专属痕迹存在=PASS | R11、R3 |
| `basic-proxy` | F1 | http 明文 GET；https CONNECT 隧道；MITM 证书有效（curl 不加 `-k`） | exit=0 且内容非空 | R1、R2 |
| `domain-matrix` | F1 | 多域可达矩阵 | 全部无响应才 FAIL，其余记录 | R7 |
| `cache-hitmiss` | F3 | 同 URL 二连发 `X-Cache-Lookup`：MISS→HIT + 耗时对照 | HIT=PASS；无头/均 MISS=数据记录 | R1、R4 |
| `integrity` | F4 | 中载荷两次下载 sha256 互比；`HEAVY=1` 加大载荷 | 哈希一致=PASS | R1、R2 |
| `failure-face` | F6 | 坏域名/拒绝端口快速干净失败 + squid 存活检查 | ≤30s 非零退出且后续正常=PASS | R1、R7 |

| 阶段（concurrency 组） | 面 | 场景 | 判定 | 规则 |
|---|---|---|---|---|
| `conc-same-object` | F5 | 按 `LADDER` 阶梯 N worker 同 URL：全部 sha256 一致 + 0 错误（一票否决）→ 记录聚合吞吐/p50 | 正确性=PASS/FAIL；吞吐仅记录 | R8.1、R9、R10 |
| `conc-distinct` | F5 | URL 池 + query 变体绕缓存键，聚合吞吐 | 全部 exit=0=PASS | R8.2、R10 |
| `conc-mixed` | F5 | pip download / git / wget / curl 四类并行 | 四类全绿=PASS | R8.3、R7 |

## 结论口径

- **PASS**：判定项全部达标（缓存 MISS→HIT 无缓存头等"数据记录"场景不阻断结论，但计入数据）。
- **FAIL**：任一判定项失败；`meta-trace` FAIL 时整套结果作废（测试本身无效——流量没走 squid）。
- 性能数字（吞吐/时延）只在与基线同 run 对比时有效（R4），跨 run 对比需同配置同 runner。
