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
| `only` | 空 | 只跑指定用例：逗号分隔的编号（`k5`）或 job id（`lfs-storeid`），如 `only=k5,p7`；空 = 全跑，PR 事件恒全跑。台账与编号见 `CASES.md`。容器层 job 的 needs 链不变，只选容器层编号时要把依赖编号一起写上（`only=p1,p1-c`） |
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
| `pip_metadata` | `0` | `1` = 启用 PEP 658 metadata 不缓存验证（CDN 压缩不发 Vary → 编码变体毒化，2026-10-31 pip hash 事故回归守卫；仅 workflow_dispatch） |
| `pip_metadata_url` | 空 | pip-metadata 组的真实 metadata URL（空 = 默认 torch wheel 的 PEP 658 metadata） |
| `apt_byhash` | `0` | `1` = 启用 apt by-hash 长缓存验证（by-hash 是内容寻址不可变索引，却被 `mutable_meta_with_by_hash` 的 deny 误伤 → 每次 `apt-get update` 全量回源；chart 0.1.31 / PR #2746 回归守卫，仅 workflow_dispatch） |
| `apt_byhash_release` | 空 | apt-byhash 组的 Release URL（空 = `repo.huaweicloud.com/ubuntu/dists/jammy/Release`；换套件/镜像时改这里） |
| `apt_byhash_index` | 空 | Release 里要跟的索引路径（空 = `main/binary-amd64/Packages.gz`；脚本按该路径在 Release 的 SHA256 段里取哈希拼 by-hash URL） |
| `lfs_store_id` | `0` | `1` = 启用 GitCode LFS/Release CDN 的 store_id 去 query 缓存键验证（K5，仅 workflow_dispatch）。内容：`lfs-cdn`（batch 双签名）+ `file-cdn`（Release 资产 302 双签名）两个域各断言「第二发命中缓存」，需目标 squid 已开 `squid.storeId.enabled`（gy-006 试点已开）。单跑用 `-f only=k5 -f lfs_store_id=1`（见 1.6） |
| `lfs_storeid_repo` | 空 | LFS 验证仓库（空 = `https://gitcode.com/ccijunk/lfs-test.git`，含 64MiB / 500MiB 两个对象，脚本自动挑体积可控的那个） |
| `lfs_storeid_max_mb` | `96` | 参与测试的 LFS 对象体积上限（MiB）；仓库里最小对象仍超限则记 SKIP |
| `lfs_storeid_asset_url` | 空 | `file-cdn` 域的 Release 资产页（空 = `zhoucungen/gitcode-oauth` 的 `install.sh`；换仓库时填任一「附件」下载页） |
| `lfs_storeid_asset_url_alt` | 空 | 同名资产的另一个 release（空 = 同仓 `v0.0.2` 的 `install.sh`）；用于证明「换内容必换路径」，防同名替换被旧副本污染 |
| `lfs_storeid_consistency_repo` | 空 | 同名替换实验仓库（空 = token 用户名下 `squid-storeid-consistency`，自动创建/删除） |

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

### 4. squid 302 × git 命令矩阵（test-git302，独立 workflow）

PR #2470 起 squid 对 github.com 的 `/<owner>/<repo>(.git)?/info/refs?service=git-upload-pack`
初始 GET 返回 302 → 集群内 git-cdn。test-squid 里的 parity 规则13 与 imagebuild 只覆盖
`clone --depth 1` 一种形态，本 workflow 用 `test-squid/repro-git-302.sh` 补齐常见远端
git 命令（ls-remote / clone / fetch / pull / remote / 按 SHA fetch / 反证），验证 302
策略对各类客户端形态都成立：

```bash
# gy-006（默认 runner）
gh workflow run test-git302.yaml --repo ascend-gha-runners/squid-gha-integration-test \
  --ref main

# 换仓库 / 打开 submodule、LFS 形态
gh workflow run test-git302.yaml --ref main \
  -f repo='https://github.com/octocat/Hello-World.git' \
  -f lfs_repo='https://github.com/git-lfs/git-lfs-test.git'
```

判定：真实 git 命令必须 `rc=0` 且 stderr 出现 `redirecting to ...git-cdn`；curl 契约探头
必须 302 且 `Location` 命中 `git-cdn-service*.svc.cluster.local:8000` 并保留路径/查询串；
负样本（archive tar.gz、仓库 HTML 页）不得跳 git-cdn；`followRedirects=false` 必须失败
（证明 302 真实存在）。结果在 artifact `test-git302` 的 `git302.tsv`。
脚本内用 `GIT_CONFIG_GLOBAL/SYSTEM=/dev/null` 剥掉宿主机 insteadOf——否则测到的是
`/root/.gitconfig` 的重写，而不是 squid 的 302。

### 5. git-cdn 最新 commit 滚动校验（test-gitcdn 的 gitcdn-latest job）

`test-gitcdn.yaml` 每 **30 分钟**（`schedule`）跑一次滚动校验，脚本
`test-squid/repro-gitcdn-latest.sh`，只测 git-cdn 本体（显式打
`git-cdn-service.git-cdn.svc.cluster.local:8000`，不经 squid、不依赖 insteadOf）：

```bash
# 手动立刻跑一轮（默认定时任务会自己跑）
gh workflow run test-gitcdn.yaml --repo ascend-gha-runners/squid-gha-integration-test \
  --ref main -f latest=1
# 只验一部分仓库（gitcode: 前缀走 git-cdn-gitcode 上游）
gh workflow run test-gitcdn.yaml --ref main -f latest=1 \
  -f latest_repos='vllm-project/vllm-ascend gitcode:cann/catlass'
```

- 仓库清单 = `ascend-ci-deployment#2048` 里跑在本套 runner 上的构建仓（vllm-ascend /
  triton-ascend / sglang / verl / pytorch …）**+ 它们的依赖仓**（vllm、triton、
  catlass、pto-isa、AscendNPU-IR），可用 `latest_repos` 覆盖。
- 每仓三步（模拟正常用 github.com 的姿势）：① 先取上游最新 commit 作真值
  （GitHub API / gitcode `ls-remote`）→ ② 经 git-cdn `fetch --depth 1` 默认分支
  HEAD 并 checkout → ③ HEAD 落后时按真值 SHA 再经 git-cdn 回源一次。
- 判定：拿不到上游最新 commit（`not our ref`、refs 落后且按 SHA 回源失败、
  checkout 失败）即 job 红；真值 API 异常、大仓库冷缓存 fetch 超时记 WARN
  （单仓上限按仓库体积估算，180~1200s）；单轮总预算 55 分钟，超出后剩余仓库记
  SKIP。结果在 artifact `test-gitcdn-latest` 的 `latest.tsv`
  （repo / 真值 SHA / cdn HEAD / 结论 / 备注 / 耗时）。
- 定时轮次不跑 `gitcdn-unsynced` job（避免每 30 分钟造一次临时 ref），该 job 仍
  在 workflow_dispatch / PR 上执行。

### 5.1 PR30/32 回归（test-gitcdn 的 gitcdn-refspec job）

`test-squid/repro-gitcdn-refspec.sh`，默认目标 `gitcode.com/ascend/pytorch`
（git-cdn-gitcode 后端），三个阶段：

- refspec：`refs/heads/*` 可读；`refs/pull/*` 只记录数量，不判红（git-cdn 的
  `info/refs` 直接代理上游，pull refs 仍会通告）
- SHA 回源：取 `refs/pull/*/head` 的 PR-only SHA（mirror 不含），两路并发
  `git fetch --depth 1 <sha>` 都成功；`/metrics` 可达时记录
  `git_cdn_fetch_sha_total` 增量，>1 记 WARN
- 失败透传：不存在的 SHA 必须在 180s 内非零退出且 stderr 有 git 错误（124=判红）

冷缓存需先在 git-cdn Pod 内删除 `/workdir` 下对应仓库目录，脚本本身不清理缓存。

### 6. GitCode LFS store_id 缓存键（test-squid 的 lfs-storeid = K5，opt-in）

opt-in job（`-f lfs_store_id=1`，需目标 squid 已开 `squid.storeId.enabled`）。
只想跑这一条用例时用 `only` 白名单，不必拉起 test-squid 的 20+ 个 job
（脚本 `test-squid/repro-lfs-storeid.sh`，用例编号 K5）：

```bash
# 与其它 job 一起跑（全量）
gh workflow run test-squid.yaml --repo ascend-gha-runners/squid-gha-integration-test \
  --ref main -f lfs_store_id=1

# 单独跑这一条（只有 lfs-storeid + summary 两个 job）
gh workflow run test-squid.yaml --ref main -f only=k5 -f lfs_store_id=1

# 换 runner / 换资产页 / 指定替换实验仓库
gh workflow run test-squid.yaml --ref main -f only=k5 -f lfs_store_id=1 \
  -f 'runner=["linux-amd64-cpu-2", "gy-006"]' \
  -f lfs_storeid_asset_url='https://gitcode.com/<o>/<r>/releases/download/<tag>/<file>' \
  -f lfs_storeid_consistency_repo='<owner>/<repo>'
```

`only` 接受编号（`k5`）或 job id（`lfs-storeid`）；未在 `only` 里的 job 记
NOT-SELECTED，summary 里逐条列出。判定见 `CASES.md` 的 K5 一行：两个 CDN 域各
断言第二发命中缓存；一致性阶段（LFS 内容寻址 / file-cdn 路径版本化 / 伪造签名）；
仓库 secret `CQ_GITCODE_TOKEN` 存在时再做「同 release 同名换内容」替换实验（路径
变了即安全，路径没变则代理/直连对照，代理供旧副本即判红）。退出码 2 = SKIP 不判红。
实测结论（run 44728228545）：同名换内容后 302 落到新的 `untagger_<uuid>` 路径，
新路径经 squid 拿到新内容 → 缓存键随内容变化，无旧副本污染。

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

git-cdn / gitcode-cdn 两个独立 workflow（`test-gitcdn.yaml`、`test-gitcode-clone.yaml`）
用同一份注册表批量触发，脚本为 `test-gitcdn-production-runners.sh`：

```bash
# 全部生产 runner × 两个 workflow（默认容器镜像用 quay 就近源）
./test-squid/test-gitcdn-production-runners.sh

# 只跑其中一个 workflow / 只跑一个 runner
./test-squid/test-gitcdn-production-runners.sh --workflow gitcdn
./test-squid/test-gitcdn-production-runners.sh --only linux-amd64-cpu-2-hk001

# 跨集群拉 cn-north-12 镜像慢时显式换 quay（默认已是 quay）
./test-squid/test-gitcdn-production-runners.sh \
  --container-image quay.io/ascend/cann:9.0.0-a3-ubuntu22.04-py3.12
```

判定口径：`test-gitcode-clone` 需要 runner 已注入 `gitcode.com → git-cdn-gitcode`
的 insteadOf（目前 gy-001 / wlcb-001），未注入的 runner 会红在重写断言；
`test-gitcdn` 显式打本地 git-cdn，集群无实例时记 SKIP（不判红）。

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
| `镜像构建网络模拟` | vllm-ascend Dockerfile.310p 外网面复刻（R18）：catlass 子模块（gitcode.com pinned commit）+ cmake 第三方压缩包（cann-src-third-party ×5 两遍拉取 sha256 比对）+ clone vllm 大 pack（squid 302 → git-cdn，**无 302 即判红**）+ OBS 静态资产（CANN `.run` Range/HEAD 带 Referer、CI 覆盖率 JSON/tar.gz 魔数、gitleaks ELF 执行、负样本 404） |
| `no_proxy × CA 注入矩阵` | CA 形态取证（纯 squid CA vs bundle）+ no_proxy 生效性 + 排他/union/追加三语义工具的直连/MITM 双路径矩阵 + 新增直连域（云元数据端点、LLM 统计/API 域，PR #2194）是否真的绕开 squid（R19，独立脚本 no-proxy-ca-test.sh；TLS-FAIL 红、NO_PROXY-MISS 红、OTHER-ERR/SKIP 不判红） |
| `gitcode × 缓存后端` | R21 opt-in（`gitcode=1`）：insteadOf 重写生效性（`git ls-remote --get-url` 展开后反推基址）+ refs 端点可达性 + 同仓库两次 `--depth 1` clone 的缓存收益（缓存头 / 耗时比 / 双快判定）。后端由 `gitcode_backend` 选：`smart-git-proxy`（gy-005）/ `git-cdn-gitcode`（gy-006 #2237 及生产集群）；`gitcode_direct=1` 可绕过重写断言只验服务本身。流量属 `.svc.cluster.local` 直连，不经过 squid，故不跑 meta-trace。**只能跑容器层**——insteadOf 由 job pod 模板的 postStart 写入 `/root/.gitconfig`，runner 容器没有这条重写；作业挂在容器链末尾串行（issue #2）并用 `always()` 保底 |
| `索引页陈旧复现` | R15 opt-in（`stale_index=1`）：2026-10-29 triton-ascend post2 构建失败回归守卫。源站索引页 `Cache-Control: max-age=1296000`（15 天）使 squid 判新鲜、不回源，镜像重新生成索引后仍供旧页（18:32:58 形态）。三个阶段：mock 机制证据（翻页后仍供旧页只打印 ⚠️，因 pod IP 主机不匹配域级 ACL）+ 真实域索引页缓存性（裸 URL ×4 + 唯一 query ×2，任一发 HIT/`fwd=stale`/Vary `mismatch` 即**判红**；query 形态专测 deny 正则是否容忍 `?`——`.../$` 写法在带 query 时失配）+ 真实索引页经 squid vs 源站直连 href 清单对照（`STALE_STRICT=1` 时 HIT 且 Age>900s 判红）。独立脚本 `repro-stale-index.sh`，runner 层 only |
| `PEP 658 metadata 不缓存` | R22 opt-in（`pip_metadata=1`）：2026-10-31 pip hash 校验事故回归守卫。CDN 按 `Accept-Encoding` 实际压缩但不发 `Vary`，squid 存储副本无 Vary 键 → 首个请求者编码定型共享（`reply_header_replace` 只改客户端响应头，不影响存储副本与缓存键）；pip metadata 请求只收 identity 且不解码（`decode_content=False`），拿到 gzip 变体后 sha256 必挂。三个判定：mock origin（三种后缀 `.whl/.tar.gz/.zip.metadata` 的 gzip 预热 + identity 请求，`Cache-Status` 出现 hit/`fwd=stale`/`detail=mismatch` 即**判红**，且 identity 响应体 sha256 必须等于源站 identity、不得是 gzip 魔数；同 host 三种本体二连发必须 HIT 作负样本守卫）+ 真实域 `.whl.metadata`（默认 torch wheel + `.metadata`）经 squid 3 发不得 HIT、identity 体与源站直连 sha256 一致 + 真实 pip 解析（`--dry-run --no-deps`，出现 hash mismatch 判红，网络/版本原因记 SKIP）。修复配置：`acl pip_metadata urlpath_regex -i \.(whl|tar\.gz|zip)\.metadata$` + `cache deny pip_metadata` + `collapsed_forwarding_access deny pip_metadata`（后缀全 host 生效，本体不受影响）。独立脚本 `repro-pip-metadata.sh`，runner 层 only |
| `apt by-hash 长缓存` | R24 opt-in（`apt_byhash=1`）：#2443 回归守卫（chart 0.1.31 / PR #2746）。`/ubuntu(-ports)/dists/.../by-hash/<alg>/<hash>` 是内容寻址不可变对象（文件名即内容 sha256，源站 `max-age=1296000`），却被 `cache deny hc_repo mutable_meta_with_by_hash` 一并拒缓存 → `apt-get update` 每次全量回源（cn12-001 单副本 81min / 592 请求 / 560 MISS / 1.8 GiB）。两个判定：`byhash`（从真实 Release 的 SHA256 段解析出对象 URL，经 squid 连打 6 发，必须出现 HIT，且每发 200 的响应体 sha256 必须等于文件名哈希 → 否则判红，全 MISS 说明 deny 例外未落地）+ `mutable`（同一 dists 下非 by-hash 的 `InRelease` / 原 `Packages.gz` 带 run 唯一 query 连打 3 发，不得由缓存作答 → 否则判红，证明 `!by_hash` 没把可变索引一起放开）。另有 `immutable` 阶段证明长缓存前提成立：源站真值两遍（不同 cache-buster）+ 条件请求（`If-None-Match` 用首遍 ETag，应 304）+ 对端镜像（`mirrors.huaweicloud.com`）同路径 + 非 by-hash 索引本体当前内容，四路都必须哈希成文件名里的 sha256，任一不符判红（内容漂移必然反映为哈希不等，所以每轮都能抓到）；该阶段不需要 squid，本地可直跑。独立脚本 `repro-apt-byhash.sh`，runner 层 only；`immutable_file` 豁免（`squid_stale_index_hit_total` 恒 0）只在 squid 内部日志/Prometheus 可见，脚本只留档 HIT 时的 Age |
| `真实工具链 e2e` | 真实客户端工具（pip/apt/npm/uv/go/wget/git-lfs/modelscope/model+dataset/git）零镜像配置跑通；另复刻上游仓库 CI 现状：`download.pytorch.org` torch 索引、`hf download` + `HF_ENDPOINT=hf-mirror.com`；`heavy=1` 追加 torch wheel 全量下载 + rustup/conda/cmake/bazel/precommit |
| ~~`git-cdn 未同步 SHA 回源复现`~~ | R23（G3）已从本套件摘除，统一在 `test-gitcdn.yaml` 的 `gitcdn-unsynced` job 执行（见 1.5），避免同一条用例两处维护 |
| `GitCode LFS store_id 缓存键` | opt-in（`lfs_store_id=1`）：两个 CDN 域各测一遍——**A. `lfs-cdn`**：两次 POST batch（同 oid）拿同路径、不同 `auth_key` 的下载 URL；**B. `file-cdn`**：同一 Release 资产两次访问，302 的 `Location` 路径相同、`auth_key` 不同（默认 `zhoucungen/gitcode-oauth` 的 `install.sh`）。每个域经 squid 各下载两次，断言 ① 两发 200 且内容 sha256 一致（LFS 还须 == pointer `oid`，证明签名没被拆坏）② 第二发响应 `Cache-Status`/`X-Cache-Lookup` 有 `hit`（决定性判据；第一发若已是命中说明对象被预热，仍能证明新签名复用既有缓存对象）③ 至少一发有 squid 痕迹，否则用例无效 ④ 负样本：非 CDN 域（默认 `pypi.org/simple/six/`）同 URL 二发 HIT、换 query 必须 MISS，证明 `store_id_access` 只放行两个 CDN 域。注意 squid 7.x 把 `TCP_REFRESH_UNMODIFIED` 也标成 `hit`，客户端无法硬区分真 `TCP_HIT`，`override-lastmod` 的收益需 access.log `HIER_NONE` 佐证。另有一致性阶段（同名/同路径换内容是否会被旧副本污染，因 refresh `min` 达 10080 分钟）：LFS 路径必须含 oid（内容寻址，不满足即判红）；file-cdn 同名资产在两个 release 下必须落在不同路径（`untagger_<uuid>`，相同只记 ⚠️）；再用伪造 `auth_key` 打已缓存路径，记录 HIT 是否会跳过签名校验（公开对象无影响，仅留档）。仓库 secret `CQ_GITCODE_TOKEN` 存在时会再做「同名替换」实证：建临时仓库/release → 上传 `probe.bin`（A）→ 经 squid 预热确认 HIT → 删附件同名重传（B）→ 再取 302 比路径；路径变了即「换内容必换键」，路径没变则代理/直连对照，代理供旧 A 而直连是新 B 判红（实证旧副本污染），结束删 release/自建仓库。file-cdn 单轮 `detail=mismatch` 会换新签名重试一轮，两轮都 MISS 才判红。前提不成立（无代理 / 域名在 NO_PROXY / 仓库无 LFS / batch 需鉴权 / 对象超上限 / 资产 URL 失效 / token 无写权限）记 SKIP。独立脚本 `repro-lfs-storeid.sh`，runner 层 only |
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
