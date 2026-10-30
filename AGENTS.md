# AGENTS.md —— squid 集成测试触发与使用指南

本仓库用 GitHub Actions（自建 runner）测试 squid 代理的**功能**与**并发**能力，
两层执行（runner 层 / CANN 容器层），另含 vLLM 通信模拟组。设计规则见 `META.md`，
场景↔规则映射见 `CASES.md`，全部脚本在 `test-squid/`。

## 一、触发方式

### 1. 手动触发（workflow_dispatch，常用）

用 `gh` CLI：

```bash
# 最简触发（全部用默认参数）
gh workflow run test-squid.yaml --repo ascend-gha-runners/squid-gha-integration-test --ref main

# 带参数触发
gh workflow run test-squid.yaml --repo ascend-gha-runners/squid-gha-integration-test --ref main \
  -f runner='["linux-amd64-cpu-2", "gy-006"]' \
  -f ladder='1 4 8 16' \
  -f heavy=0
```

参数说明：

| 参数 | 默认值 | 说明 |
|---|---|---|
| `runner` | `["linux-amd64-cpu-2", "gy-006"]` | runner 标签，**JSON 数组字符串**。数组内多标签是 AND 关系（必须全命中）。⚠️ 不要写成逗号字符串——表达式里的逗号串不会拆成多标签，job 会永久 queued |
| `ladder` | `1 4 8 16` | 同对象并发的阶梯并发度 |
| `heavy` | `0` | `1` = 启用 ~146MB 大载荷场景（耗时长，日常不用开） |
| `np_strict` | `0` | `1` = 新增直连域（云元数据端点 + LLM 统计/API 域）必须全部命中 NO_PROXY，用于 gy-006 cpu-2 配置落地验证；默认宽松（未纳入本批的 runner set 记 SKIP） |
| `gitcode` | `0` | `1` = 启用 gitcode.com → 缓存后端的 insteadOf 重写与缓存命中验证（仅 workflow_dispatch；必须容器层，目标 runner 需已由 postStart 注入重写） |
| `gitcode_backend` | `smart-git-proxy` | 缓存后端：`smart-git-proxy`（gy-005，带 `/gitcode.com` 前缀段）/ `git-cdn-gitcode`（gy-006 及已完成改造的生产集群，`git-cdn-gitcode` 命名空间根路径直挂） |
| `gitcode_direct` | `0` | `1` = 跳过 insteadOf 断言，直接打后端基址，只验缓存服务本身（目标 runner 无法派发时用） |
| `gitcode_lfs_repo` | 空 | LFS 验证目标仓库 URL（如 `https://gitcode.com/ascend/pytorch.git`）；空=用 `GITCODE_REPO`，其 `.gitattributes` 无 `filter=lfs` 则记 SKIP |
| `container_image` | swr cn-north-12 CANN | CANN 容器层镜像。跨集群拉取慢（如 hk-001 拉 10GB 卡 30min+）时换就近仓库：`quay.io/ascend/cann:9.0.0-a3-ubuntu22.04-py3.12` |
| `openeuler_image` | swr cn-southwest-2 openEuler | dnf/yum 容器层镜像。同上，可换 `quay.io/openeuler/openeuler:24.03` |
| `stale_index` | `0` | `1` = 启用索引页陈旧复现（源站 max-age 15 天 → squid 长期供旧页，R15 回归守卫；仅 workflow_dispatch） |
| `stale_strict` | `1` | stale-index 严格模式：经 squid HIT 且 Age > 900s 判红（验证短 TTL 规则已落地） |

也可在 GitHub 网页端触发：仓库 → **Actions** → **test-squid** → **Run workflow**。

### 2. 自动触发（pull_request）

修改以下路径的 PR 会自动跑一遍（固定 `linux-amd64-cpu-2, gy-006`）：

- `test-squid/**`（任何测试脚本/mock 改动）
- `.github/workflows/test-squid.yaml`

### 3. 调试探针（probe-domain，长期保留）

排查单个 runner 出网问题时用，不参与 test-squid 判定：

```bash
# 在 sh-001 上按域名矩阵探测（每个域同时走 squid 与直连作对照）
gh workflow run probe-domain.yaml --repo ascend-gha-runners/squid-gha-integration-test \
  --ref main -f 'runner=["linux-aarch64-a5-2-sh001"]' -f repeat=5
```

结果在 artifact `probe-domain` 的 `probe.tsv`（host/path/attempt/via/code/time），
`via=proxy` 是经 squid、`via=direct` 是 `--noproxy '*'` 直连对照。

## 二、前置条件（缺一不可）

1. **runner 注入 squid**：目标 runner set 的 pod 模板必须已注入
   `HTTP(S)_PROXY`/`HTTPS_PROXY` 指向 squid service（`squid-cache.squid.svc:3128`）
   + 挂载并信任 `squid-ca-cert`（MITM）。workflow 内**故意不配任何代理**——
   流量必须由环境注入，这是被测对象本身。
2. **runner group 放行**：runner 所属 group（`openmerlin-guiyang-006-cluster`）
   需允许本仓库（当前已配置）。
3. **仓库 public**：CANN 镜像自带的 gitconfig 会把 github.com 重写到 gh-proxy
   （这是环境正道，保留），public 仓库匿名即可拉取，无需额外凭据。

## 二点五、生产 runner 批量验证

除 gy-006（测试集群）外，其余 runner set 都在生产集群。集群侧注入
（caNamespaces / env / CA 卷 / postStart）由平台侧维护；验证用批量脚本
**不需要 kubeconfig**，纯 `gh` 逐个触发 test-squid：

```bash
# 全部生产 runner 并行测（先全触发、再并行盯，汇总表，任一非绿退出码 1）
./test-squid/test-production-runners.sh

# 只测一个 / 只列注册表 / 只触发不等结果
./test-squid/test-production-runners.sh --only cpu-2-hk001
./test-squid/test-production-runners.sh --list
./test-squid/test-production-runners.sh --no-watch
```

生产 runner 注册表（脚本内 `RUNNERS` 数组维护；每个 runner 有 3 个可选标签，
脚本统一用**全局唯一名**做单标签触发，避免多标签 AND 语义）：

| 标签 | 集群 | 注入状态 |
|---|---|---|
| `linux-aarch64-a3-2-aiframe` | aiframework | caNamespaces 已有；aarch64（amd64 容量死锁，run 38370252096 实证换型） |
| ~~`linux-amd64-cpu-2-aiframe`~~ | aiframework | **不使用**：amd64 无容量（`FailedScheduling: 2 Insufficient cpu`，autoscaler 已到 node group 上限），2026-10-23 实测 job 永久 Pending |
| `linux-amd64-cpu-2-gy003` | gy-003 | caNamespaces 已有，仅注入 |
| `linux-amd64-cpu-2-hk001` | hk-001 | 新增 postStart（原无 lifecycle）；CM 在 `ascend-gha-runners-hk-001` ns |
| `linux-amd64-cpu-2-mind-third` | mind-third-ci | caNamespaces + ascend-gha-runners |
| `linux-amd64-cpu-4-gy004` | gy-004 | caNamespaces 已有，仅注入 |
| `linux-amd64-cpu-8-gy005` | gy-005 | 保留 karpenter 注解；caNamespaces + ascend-gha-runners |
| `linux-amd64-cpu-4-cn12-001` | cn12-001 | 已注入（2026-10-08，workflow pod 实测 env/CA 卷齐全） |
| `linux-aarch64-a5-2-sh001` | sh-001 | 新增（2026-10-26）；aarch64 A5 |
| `linux-amd64-a5-2-sh002` | sh-002 | 新增（2026-10-26）；amd64 A5 |

## 三、job 结构

| job | 内容 |
|---|---|
| `squid 功能测试` | 元自检、基本代理/CONNECT/MITM、缓存 MISS→HIT、sha256 完整性、失败面、artifact 下载 |
| `squid 并发测试` | 同对象阶梯并发、异对象并发、混合工具并行 |
| `vllm 通信模拟` | ModelScope/HF 双通道模型下载 + OpenAI API 8 并发 SSE（自带 mock origin） |
| `透明重写同构校验` | no-mirror tool-17 全量移植：13 条重写规则内容签名 + 负样本 + 回归守卫（runner 层 only） |
| `上游通道健康` | gh-proxy 延迟预算（p50≤5s，A/B 对照）+ read_timeout 数据留档（R17，runner 层 only；Actions 构件通道已入 NO_PROXY 直连，不测不过 squid 的流量） |
| `镜像构建网络模拟` | vllm-ascend Dockerfile.310p 外网面复刻（R18）：catlass 子模块（gitcode.com pinned commit）+ cmake 第三方压缩包（cann-src-third-party ×5 两遍拉取 sha256 比对）+ GIT_PROXY insteadOf clone vllm（大 pack 吞吐）+ OBS 静态资产（CANN `.run` Range/HEAD 带 Referer、CI 覆盖率 JSON/tar.gz 魔数、gitleaks ELF 执行、负样本 404） |
| `no_proxy × CA 注入矩阵` | CA 形态取证（纯 squid CA vs bundle）+ no_proxy 生效性 + 排他/union/追加三语义工具的直连/MITM 双路径矩阵 + 新增直连域（云元数据端点、LLM 统计/API 域，PR #2194）是否真的绕开 squid（R19，独立脚本 no-proxy-ca-test.sh；TLS-FAIL 红、NO_PROXY-MISS 红、OTHER-ERR/SKIP 不判红） |
| `gitcode × 缓存后端` | R21 opt-in（`gitcode=1`）：insteadOf 重写生效性（`git ls-remote --get-url` 展开后反推基址）+ refs 端点可达性 + 同仓库两次 `--depth 1` clone 的缓存收益（缓存头 / 耗时比 / 双快判定）。后端由 `gitcode_backend` 选：`smart-git-proxy`（gy-005）/ `git-cdn-gitcode`（gy-006 #2237 及生产集群）；`gitcode_direct=1` 可绕过重写断言只验服务本身。流量属 `.svc.cluster.local` 直连，不经过 squid，故不跑 meta-trace。**只能跑容器层**——insteadOf 由 job pod 模板的 postStart 写入 `/root/.gitconfig`，runner 容器没有这条重写；作业挂在容器链末尾串行（issue #2）并用 `always()` 保底 |
| `索引页陈旧复现` | R15 opt-in（`stale_index=1`）：2026-10-29 triton-ascend post2 构建失败回归守卫。源站索引页 `Cache-Control: max-age=1296000`（15 天）使 squid 判新鲜、不回源，镜像重新生成索引后仍供旧页（18:32:58 形态）。三个阶段：mock 机制证据（翻页后仍供旧页只打印 ⚠️，因 pod IP 主机不匹配域级 ACL）+ 真实域索引页缓存性（裸 URL ×4 + 唯一 query ×2，任一发 HIT/`fwd=stale`/Vary `mismatch` 即**判红**；query 形态专测 deny 正则是否容忍 `?`——`.../$` 写法在带 query 时失配）+ 真实索引页经 squid vs 源站直连 href 清单对照（`STALE_STRICT=1` 时 HIT 且 Age>900s 判红）。独立脚本 `repro-stale-index.sh`，runner 层 only |
| `真实工具链 e2e` | 真实客户端工具（pip/apt/npm/uv/go/wget/git-lfs/modelscope/model+dataset/git）零镜像配置跑通；另复刻上游仓库 CI 现状：`download.pytorch.org` torch 索引、`hf download` + `HF_ENDPOINT=hf-mirror.com`；`heavy=1` 追加 torch wheel 全量下载 + rustup/conda/cmake/bazel/precommit |
| `容器层·*（CANN 镜像）` | 功能/并发/vllm/工具链/miss-p95/镜像构建/no_proxy×CA 矩阵七组在 `cann:9.0.0-a3-ubuntu22.04-py3.12` 容器里各跑一遍（多验 CA 信任路径 + 镜像内 gitconfig 形态）；容器层 job 用 needs 链串行（container hook 并发挂死竞态，issue #2） |
| `容器层·dnf/yum（openEuler 24.03）` | R20：`swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/openeuler/openeuler:24.03` 里真实跑 `dnf makecache` + `dnf install tree` + `yum install jq`；首步 dnf 装 `git-core` 引导 checkout。这是套件里唯一覆盖 RHEL 系 CA 信任路径（anchors + `update-ca-trust`，不靠 CA env）的样本 |
| `汇总` | 聚合全部 job 结果表到 GITHUB_STEP_SUMMARY |

## 四、看结果

```bash
# 状态 / 结论
gh run list --repo ascend-gha-runners/squid-gha-integration-test --workflow test-squid.yaml --limit 3
gh run view <run_id> --repo ascend-gha-runners/squid-gha-integration-test

# 某个 job 的关键判定行（✅/❌/⚠️ 与耗时）
gh run view --job <job_id> --repo ascend-gha-runners/squid-gha-integration-test --log \
  | grep -aE '###|✅|❌|⚠️'
```

- **GITHUB_STEP_SUMMARY**：run 页面右侧 Summary 即总表
- **Artifacts**（`test-squid-*`）：
  - `timings.tsv` —— 各阶段 PASS/FAIL 与耗时
  - `probes.tsv` —— 各探测点的原始证据（状态码、Cache-Status、耗时）
  - `origin-*.log` —— mock origin 日志（仅 vllm 组）
- **判定口径**：TSV 里任一 FAIL → 套件非零退出 → job 红；`⚠️` 仅记录数据不影响结论

## 五、本地冒烟（可选，改脚本后先自测）

```bash
# 本地无 squid：meta-trace 会判 FAIL（预期，流量确实没走代理），
# 其余阶段用直连验证脚本逻辑；TSV 落在 $RESULTS_DIR
RESULTS_DIR=/tmp/squid-smoke bash test-squid/run-suite.sh --mode vllm
```

⚠️ 本地冒烟只能验证**脚本逻辑**，代理/缓存行为必须在注入 squid 的 runner 上验证。
