# squid-gha-integration-test

squid 代理的 GitHub Actions 集成测试：**功能 + 并发**。

## 结构

```
META.md                            # 元测试设计规则（所有场景必须满足的设计律）
CASES.md                           # 场景设计（场景 ↔ 元规则映射）
test-squid/run-suite.sh            # 测试主脚本（run_timed 阶段计时 + TSV 汇总）
.github/workflows/test-squid.yaml  # 入口 workflow（workflow_dispatch + pull_request）
```

## 测试内容

| 组 | 场景 |
|---|---|
| function | 元自检（squid 专属痕迹）、http/https/MITM 代理、缓存 MISS→HIT、传输完整性 sha256、失败面（坏域名快速失败 + squid 存活） |
| concurrency | 同对象阶梯并发（LADDER 默认 1→4→8→16，正确性一票否决）、异对象并发聚合吞吐、pip/git/wget/curl 混合并行 |

## 运行

- **手动**：Actions → test-squid → workflow_dispatch，可选 runner 标签 / LADDER / HEAVY
- **PR**：改动 `test-squid/**` 或 workflow 文件自动触发（默认参数）

runner 默认 `linux-amd64-cpu-2, gy-006`（多标签 AND 匹配，CPU 轻量任务），
需已由 pod 注入 squid 代理（HTTP(S)_PROXY + MITM CA），workflow 内不配置任何代理。

本地直跑：

```bash
bash test-squid/run-suite.sh --mode function
LADDER="1 4 8 16" bash test-squid/run-suite.sh --mode concurrency
```

结果：`/tmp/test-squid-results/timings.tsv`（status：0=PASS / 1=FAIL / SKIP=数据记录）。
