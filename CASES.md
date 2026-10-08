# 场景设计（两层测试对象 × 两组场景）

> 按 [META.md](./META.md) 元规则推导的场景矩阵。
> 每个场景：独立阶段、失败不传染（R7）、结果写 TSV（R2/R7）。

## 两层测试对象

squid 注入在两种执行形态下必须**都**生效，测试分两层覆盖：

| 层 | 执行形态 | 注入路径 | 差异点（为什么必须分开测） |
|---|---|---|---|
| **runner 层** | workflow job 直接跑在 runner 的 job pod | pod template 的 env（HTTP(S)_PROXY）+ CA env + secret 卷挂载 + postStart 灌系统信任库 | runner 镜像自带 CA 库，postStart hook 可靠 |
| **container 层** | workflow job 声明 `container:` 跑进用户镜像 | 同一套 pod template 应用于 job 容器（`$job`） | **用户镜像的 CA 库形态不可控**（Alpine/Debian/RHEL 各异、可能缺 `ca-certificates` 包）、libc/工具链不同、`update-ca-*` 可能不存在——正是 postStart 兜底逻辑要覆盖的 |

container 层使用与 CI 真实 workload 相同的镜像：
`swr.cn-north-12.myhuaweicloud.com/base_image/ascend-ci/cann:9.0.0-a3-ubuntu22.04-py3.12`，
验证「用户容器里 squid 注入零配置可用」。镜像缺工具（wget/git 等）时记 SKIP 不判失败。

## 通用约定

实现为 **GitHub workflow + 单脚本**（runner = squid 注入的 GHA runner）：

```
.github/workflows/test-squid.yaml   # 入口：workflow_dispatch + pull_request
test-squid/run-suite.sh             # 全部场景逻辑（run_timed 阶段计时 + TSV）
```

workflow 四个 job 调同一脚本（runner 层 × container 层 × function/concurrency 两组），
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

两组场景在**两层对象上各跑一遍**（runner 层与 container 层的 job 名带层后缀）。

### function 组

| 阶段 | 面 | 场景 | 判定 | 规则 |
|---|---|---|---|---|
| `env-snapshot` | — | 代理注入环境快照（只读）：proxy env、CA env、CA 文件存在性 | 留档 | R1 |
| `meta-trace` | — | **squid 专属痕迹检查**：响应必须带 `Cache-Status: squid-cache`（squid 7.x，RFC 9211）或 `Via` 含 `squid` 标识，否则整套测试无效（流量没走 squid；ISP 缓存的 Via 属假阳性） | squid 专属痕迹存在=PASS | R11、R3 |
| `basic-proxy` | F1 | http 明文 GET；https CONNECT 隧道；MITM 证书有效（curl 不加 `-k`） | exit=0 且内容非空 | R1、R2 |
| `domain-matrix` | F1 | 多域可达矩阵 | 全部无响应才 FAIL，其余记录 | R7 |
| `cache-hitmiss` | F3 | 同 URL 二连发，解析 `Cache-Status`（miss/hit/mismatch）+ 耗时对照 | HIT=PASS；无头/均 MISS=数据记录 | R1、R4 |
| `integrity` | F4 | 中载荷两次下载 sha256 互比；`HEAVY=1` 加大载荷 | 哈希一致=PASS | R1、R2 |
| `failure-face` | F6 | 坏域名/拒绝端口快速干净失败（**curl 必须 `-f`**：squid 对坏域回 502 错误页，无 `-f` 时 rc=0 属误判）+ squid 存活检查 | ≤30s 非零退出且后续正常=PASS | R1、R7 |

### concurrency 组

| 阶段 | 面 | 场景 | 判定 | 规则 |
|---|---|---|---|---|
| `conc-same-object` | F5 | 按 `LADDER` 阶梯 N worker 同 URL：全部 sha256 一致 + 0 错误（一票否决）→ 记录聚合吞吐/p50 | 正确性=PASS/FAIL；吞吐仅记录 | R8.1、R9、R10 |
| `conc-distinct` | F5 | URL 池 + query 变体绕缓存键，聚合吞吐 | 全部 exit=0=PASS | R8.2、R10 |
| `conc-mixed` | F5 | pip download / git / wget / curl 四类并行 | 四类全绿=PASS | R8.3、R7 |

### vllm 组（mock vLLM 通信）

模拟 vLLM 生命周期两类真实通信形态，origin 为套件自带 mock（`mock-vllm-origin.py`，
纯标准库，确定性生成模型文件），流量**显式 `-x` 走 squid**（不受 NO_PROXY 影响）；
两层各跑一遍（`--mode vllm [--container]`）。

| 阶段 | 面 | 场景 | 判定 | 规则 |
|---|---|---|---|---|
| `meta-trace` | — | 同功能组元自检（mock 流量同样必须经 squid） | FAIL 整套作废 | R11、R3 |
| `vllm-model-pull` | F5/F3 | **HF hub 下载形态**：元数据顺序拉（config/tokenizer）+ 4 worker 并行权重（2 全量 sha256 对 manifest + 2 Range 半拉断点续传）；热复拉验缓存命中 | 完整性一票否决=PASS/FAIL；命中仅记录 | R8、R2、R4 |
| `vllm-api-stream` | F5/F1 | **OpenAI 兼容 API 形态**：8 并发流式 POST（SSE 8 chunk + [DONE] 完整性）+ 非流式 + /v1/models；验证 squid 转发 POST/SSE 不断流不缓存 | 全绿=PASS | R8.3、R1、R7 |

mock 说明：模型文件按 tag+块序号哈希确定性生成（16MB+8MB 权重），每 run 用
`$GITHUB_RUN_ID` 唯一 tag → 冷拉必 MISS、热复拉可观测 HIT；origin 服务在阶段内
起停（失败不传染，R7）。本地无代理 env 时自动直连并记 SKIP（只验 mock 逻辑）。

### container 层追加检查

| 阶段 | 面 | 场景 | 判定 |
|---|---|---|---|
| `ca-trust` | F4 | 容器内系统信任库是否含 squid CA（`update-ca-trust`/`update-ca-certificates`/raw bundle 三条路径之一生效） | 校验 openssl 验证链无错=PASS |

### parity 组（透明重写同构校验，源自 no-mirror-test tool-17 全量移植）

gy-006 的 squid 启用 `url_rewrite_program`：客户端零镜像配置，官方 URL 服务端透明
重写到镜像站。该组在 runner 层单独跑（重写是 squid 服务端行为，与客户端环境无关，
无需容器层重复）。**内容签名层**判定（runner 不挂 squid-config CM，helper 断言层
不可用——R13 环境边界）；脚本内唯一显式镜像 URL 是负样本（R14）。

| 检查点 | 规则 | 判定（状态码 + 魔数/内容签名） |
|---|---|---|
| pypi-simple / pypi-packages（动态取真实 wheel） | 规则1/12：索引页 + files.pythonhosted 对象域 | 200/206 + 相对路径或官方 URL |
| gh-archive / gh-release / gh-raw | 规则3/13：gh-proxy 前缀式 | gzip 魔数 `1f8b08` / ELF 魔数 `7f454c46` / 200 |
| goproxy-list / go-tarball / go-json | 规则5：goproxy.cn 同构 / aliyun tarball / `?mode=json` 分流 | `^v` / gzip / `"` version` JSON（tool-18 事故回归位，R15） |
| ubuntu-release / ports-release | 规则6：apt host 交换 | `Origin: Ubuntu` |
| npm-doc / npm-tgz | 规则7：registry.npmmirror host 交换 | `"versions"` / gzip |
| crates-index / crates-config / crates-static | 规则8：rsproxy sparse index | `"vers"` / `api/v1/crates` 模板漂移守卫（R15）/ gzip |
| conda-cloud / conda-pkgs / miniconda | 规则9：nju `/cloud/` 前缀重映射 | HEAD 200（repodata 百 MB 级只探头） |
| openeuler-repomd | 规则10：yum host 交换 | `<repomd` |
| rustup-manifest / rustup-init | 规则10a：huaweicloud 固定映射 | `manifest-version` / HEAD 200 |
| NEG conda-nocloud（故意错映射，直连镜像） | R14 负样本 | 期望 404/403：证明判定方法有效 |

### tools 组（真实工具链 e2e，no-mirror 形态移植）

no-mirror-test tool-* 用例剥环境壳移植（R16：业务命令零镜像配置原样保留）。
工具链缺失记 SKIP（数据），在而失败记 FAIL。`HEAVY=1` 追加编译/工具链级重场景。
runner 与 CANN 容器层各跑一遍。

| 阶段 | 对应原用例 | 场景（零镜像配置） | 规则 |
|---|---|---|---|
| `tool-pip` | tool-01 | pip 官方 index 下载→安装→import（极简 runner 缺 pip 时 ensurepip/apt 兜底，兜底本身也是真实 apt 链路） | R12、R13 |
| `tool-apt` | tool-02 | 官方源零换源 `apt-get update && install jq` | 规则6 |
| `tool-npm` / `tool-pnpm` | tool-09/15 | 默认 registry 安装 express / bootstrap pnpm 后安装 | 规则7 |
| `tool-uv` | tool-12 | pip bootstrap uv + uv pip install | 规则1 |
| `tool-goproxy` | tool-04 | go 缺失时官方 tarball bootstrap（squid 大文件下载）+ `go mod download` | 规则5 |
| `tool-wget` | tool-06 | 官方 github release wget + ELF 魔数 | 规则3 |
| `tool-gitlfs` | tool-14 | git-lfs 官方 release bootstrap（curl，极简镜像无 wget） | 规则3 |
| `tool-modelscope` | —（vllm-ascend 增补） | modelscope CLI 官方源下载 Qwen config（天然 302→CDN） | R12 |
| `tool-git` | tool-03 | github.com 直连 clone（runner 层 no-mirror 形态；容器层 insteadOf 走 gh-proxy，两形态都记录） | R12 |
| `tool-rustup`（heavy） | tool-19 | sh.rustup.rs bootstrap + cargo serde 构建 | 规则10a、8 |
| `tool-conda`（heavy） | tool-11 | miniconda 官方 installer + conda-forge numpy | 规则9 |
| `tool-cmake`（heavy） | tool-07 | googletest 直连 clone + cmake 构建 | R12 |
| `tool-bazel`（heavy） | tool-08 | bazelisk（官方 release）+ bazel_dep 构建 | 规则3 |
| `tool-precommit`（heavy） | tool-18 | pre-commit + gitleaks 官方 hook repo | 规则3 |

排除留档（R16）：tool-13 huggingface（helper 无 hf 规则，前版显式 hf-mirror 违例已删）、
tool-16 yum（GHA/CANN 均 ubuntu，无 openEuler 基底）、tool-17 docker-pull 与
tool-20 buildkit（需 docker/buildkitd 服务端，机制不同归 e2e 平台测试）。

### upstream 组（上游通道健康，R17，runner 层 only）

源自 cn12-001 runbook 诊断（2026-10-08）：单 pod 6h 内 17 次 TIMEDOUT，53% 集中在
GitHub Actions 构件通道（出口固有抖动，代理侧不可修）；gh-proxy test 实例 4 次
超时且实测 p50 3.2s（配置选择问题，可修）。本组把诊断判据固化为自动化测试——
**单次失败仅记录，单域集中失败才 FAIL**（对齐告警降噪口径 `sum by (host) > 3`）。

| 阶段 | 场景 | 判定 | 规则 |
|---|---|---|---|
| `actions-channels` | Actions 构件上传/下载通道各 3 次探测：`productionresultssa3.blob.core.windows.net`（Azure blob 下载）、`results-receiver.actions.githubusercontent.com`（CreateArtifact 上传） | 可达=2xx–4xx 应答（未认证 4xx 属预期；**5xx 不算**——经代理时 5xx 主要是 squid 错误页，与超时同属失败）。3/3=PASS；2/3=PASS+⚠️（1/3 失败率留档，速率归 Prometheus）；≤1/3=FAIL（集中失败=出口/上游黑洞） | R17 |
| `ghproxy-health` | gh-proxy（`GHPROXY_URL`，默认 gh-proxy.test.osinfra.cn）真实拉取 octocat README ×3（URL 形态对齐 CANN gitconfig insteadOf） | 3/3 成功且 p50 ≤ 5s=PASS；拉取集中失败或 p50 > 5s=FAIL（3.2s 已属不健康形态） | R17 |
| `slow-upstream` | 静默上游：本机 python 监听 accept 后不响应，`-x` 强制走 squid 测 read_timeout 实际形态 | 仅数据留档不判结论（CI 时限内无法观测 30min 超时；若 squid 短超时内回 504 说明 fail-fast 已生效） | R17 |

runner 层 only 的原因：Actions 构件通道与 gh-proxy 是 runner 环境关心的事，
与执行层（容器 CA/工具链）无关；且 results-receiver 上传域在容器层无语义。

## 结论口径

- **PASS**：判定项全部达标（缓存 MISS→HIT 无缓存头等"数据记录"场景不阻断结论，但计入数据）。
- **FAIL**：任一判定项失败；`meta-trace` FAIL 时整套结果作废（测试本身无效——流量没走 squid）。
- **套件退出码 gate**：run-suite.sh 结束时按 TSV 汇总——存在 status=1 的阶段 → 脚本非零退出，
  workflow job 随之 FAIL（禁止"阶段失败但 job 全绿"）。
- 性能数字（吞吐/时延）只在与基线同 run 对比时有效（R4），跨 run 对比需同配置同 runner。

## 已知实现注记（2026-09-29 首轮 run 实测反馈）

| 发现 | 处置 |
|---|---|
| squid 7.7.2 发 `Cache-Status: squid-cache;detail=…`（RFC 9211），不发老式 `X-Cache-Lookup` | cache-hitmiss 解析改为 Cache-Status 优先 |
| squid 对坏域回 502 错误页，curl 无 `-f` 时 rc=0 | failure-face 一律加 `-f` |
| 阶段 FAIL 后 job 仍 success | run-suite.sh 末尾加 TSV 汇总退出码 |
| **容器层发现**：CANN 镜像自带 `/root/.gitconfig`，全局 `insteadOf` 把 github.com 重写到 `gh-proxy.test.osinfra.cn`；checkout 失败根因是 token extraheader 挂在 `http.https://github.com/` 上，重写后 URL 不匹配 → gh-proxy 收到匿名请求 → 401（run 36538608282 实锤）。**gh-proxy 是环境正道，gitconfig 保留、不需要 gh-proxy 专属凭据** | checkout 前给重写目标挂同一份 token：`HOME=/root git config --global http.https://gh-proxy.test.osinfra.cn/.extraheader "AUTHORIZATION: basic …"`；另加独立场景 `artifact-download`：runner 层上传随机载荷，容器层用 `dawidd6/action-download-artifact@v9` 按 `run_id` 下载并 sha256 校验（GHA artifact 流量经 squid） |
