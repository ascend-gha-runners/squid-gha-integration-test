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
| `cache-hitmiss` | F3 | 同 URL 二连发，解析 `Cache-Status`（miss/hit/mismatch）+ 耗时对照 | HIT=PASS；无头/均 MISS=数据记录 | R1、R4 |
| `integrity` | F4 | 中载荷两次下载 sha256 互比；`HEAVY=1` 加大载荷 | 哈希一致=PASS | R1、R2 |
| `failure-face` | F6 | 坏域名/拒绝端口快速干净失败（**curl 必须 `-f`**：squid 对坏域回 502 错误页，无 `-f` 时 rc=0 属误判）+ squid 存活检查 | ≤30s 非零退出且后续正常=PASS | R1、R7 |

### concurrency 组

| 阶段 | 面 | 场景 | 判定 | 规则 |
|---|---|---|---|---|
| `conc-same-object` | F5 | 按 `LADDER` 阶梯 N worker 同 URL：全部 sha256 一致 + 0 错误（一票否决）→ 记录聚合吞吐/p50 | 正确性=PASS/FAIL；吞吐仅记录 | R8.1、R9、R10 |
| `conc-distinct` | F5 | URL 池 + query 变体绕缓存键，聚合吞吐 | 全部 exit=0=PASS | R8.2、R10 |
| `conc-mixed` | F5 | pip download / git / wget / curl 四类并行 | 四类全绿=PASS | R8.3、R7 |

### vllm 组（mock vLLM 通信，逐 case 对照 vllm-ascend 真实用例）

case 设计以 `vllm-ascend` 仓库真实测试用例为蓝本（逐条对照见下文
「vllm-ascend 真实 case 对照」），origin 为套件自带 mock（`mock-vllm-origin.py`，
纯标准库，确定性生成模型文件）。**流量路径按真实 CI 形态分流**：

- **模型下载过 squid**（对齐真实 #5：CI 用 `VLLM_USE_MODELSCOPE=True`，`vllm serve`
  继承注入的 HTTP(S)_PROXY，模型下载确实过代理——这是真实 CI 里唯一过 squid 的路径）
- **API 通信 127.0.0.1 直连**（对齐真实 #1/#2/#4：server/client 同 pod，API 流量全部
  localhost，从不过代理——旧版强行塞过 squid 测的是不存在的拓扑，且是无缓存头请求
  撞 squid 陈旧缓存事故的根源）

两层各跑一遍（`--mode vllm [--container]`）。

| 阶段 | 面 | 场景 | 判定 | 规则 |
|---|---|---|---|---|
| `meta-trace` | — | 同功能组元自检（验证 runner 注入环境本身） | FAIL 整套作废 | R11、R3 |
| `vllm-model-pull` | F5/F3 | **模型下载形态（真实 #5）**：ModelScope `repo?Revision=$run_tag&FilePath=…` + HF `resolve/$run_tag/` 双通道（Revision 段 run 唯一——真实 ModelScope/HF 的 URL 本就是 Revision/commit 内容寻址，缓存键跨 run 不撞）；元数据顺序拉 + 4 worker 并行权重（2 全量 sha256 对 manifest + 2 Range 半拉断点续传）；热复拉冷拉同 URL 验缓存命中 | 完整性一票否决=PASS/FAIL；命中仅记录 | R8、R2、R4 |
| `vllm-api-stream` | F5/F1 | **OpenAI 兼容 API 形态（真实 #1/#2/#3/#4，127.0.0.1 直连不过 squid）**：8 并发流式 POST（SSE 8 chunk + [DONE] 完整性）+ /v1/models + X-Request-ID 三断言（非流式响应 id=`chatcmpl-{ID}` 回显 endswith、流式 chunk id 透传 + [DONE]、重复 ID 三连发各 200/400——vLLM DuplicateRequestError 形态，allow_400 语义对齐 test_request_id.py 2×2×2 矩阵） | 全绿=PASS | R8.3、R7 |

mock 说明：模型文件按 tag+块序号哈希确定性生成（16MB+8MB 权重），run tag 同时进
**文件内容**与 **URL Revision 段**（内容寻址）→ 同 run 冷拉 MISS、热复拉同 URL 可
观测 HIT、跨 run 缓存键不撞；origin 服务在阶段内起停（失败不传染，R7）；探活与
API 阶段 127.0.0.1 直连（对齐真实拓扑）。本地无代理 env 时 model-pull 自动直连
（只验 mock 逻辑，缓存/代理行为不判）。

#### vllm-ascend 真实 case 对照（2026-10-09 取证 `../vllm-ascend-forked`）

原则：**每条 mock case 必须指到 vllm-ascend 仓库的真实用例**，形态保真优先。
下表保真度为取证时点状态（#1/#3 的偏离已在下文修正清单落地）。

| # | 真实 case | 它做什么 | 我们对应阶段 | 保真度 |
|---|---|---|---|---|
| 1 | `e2e/conftest.py:337,393-445` | RemoteOpenAIServer `vllm serve` 子进程，循环 `requests.get http://127.0.0.1:8000/health` 直到 200（5s 间隔） | `wait_origin` 探活 | ⚠️ 语义同（GET /health 轮询到 200），旧版路径不同：真实是 localhost 直连，我们曾绕 squid 打 pod IP（已修正为直连） |
| 2 | `weekly/single_node/engine_func_test_robot/tests/test_*.py`（temperature/max_tokens/stop 等十几个） | 原生 requests `POST /v1/chat/completions`，断言 200 + SSE [DONE] + finish_reason，绝大多数 stream=True | `vllm-api-stream` 流式 POST | ✅ 形态一致（断言 8 chunk + [DONE]） |
| 3 | `.../test_request_id.py:9,78` | X-Request-ID 透传 + 重复 ID → 400，3 worker，同步+流式 | 非流式 POST 的 X-Request-Id 回显 | ⚠️ 旧版只做了回显半件事，没做重复 ID→400（已补齐三断言） |
| 4 | `features/structured_output/test_openai_api.py:41-75` | openai SDK，32 请求 / 8 worker，流式+非流式混合 | 8 并发流式 POST | ✅ 并发规模直接对齐 |
| 5 | 模型下载：`VLLM_USE_MODELSCOPE=True`（`_e2e_nightly_single_node_models.yaml:85`）→ `vllm serve` 继承 env 内部下载 | ModelScope/HF 客户端路径下载 | `vllm-model-pull`（ModelScope repo API + HF resolve + Range 续传 + 4 并行） | ✅ 下载形态复刻；**真实 CI 里这是唯一存在代理的路径**（`vllm serve` 继承注入的 HTTP(S)_PROXY，下载确实过 squid） |
| 6 | `ut/proxy/test_load_balance_proxy_server.py:26-30` | 他们自己的 load-balance proxy 起在 127.0.0.1:19080，mock 后端 127.0.0.1:19001/19002，脚本化 SSE + 死后端注入 | （无对应——我们用 squid 替代了他们的 proxy 角色） | ⚠️ 真实 proxy 测试全程 loopback，从不按 pod IP 寻址后端 |
| 7 | `one_card/rlhf/`：/sleep /wake_up /pause /resume /metrics 生命周期 | NPU 特有控制面 | 无 | 按约定 mock NPU case 跳过 |

#### 对照暴露的三个偏离（均为旧版 case 设计问题）

1. **#1 探活 + #2/#4 客户端**：真实 case 全部 **localhost 直连**
   （127.0.0.1/localhost:8000/8770），无代理。旧版把 API 流量强行塞过 squid
   （pod IP + `-x`）——测的是真实 CI 不存在的拓扑，且是无缓存头请求撞 squid
   陈旧缓存事故（gy-005/gy003：`TCP_REFRESH_FAIL_OLD_ABORTED` 假阳性探活 →
   POST 打到未就绪 origin 全灭）的根源。
2. **#5 下载**：这条**真实过代理**（env 继承），mock 过 squid 反而是保真的——
   但旧版 URL 跨 run 不变（固定 18081 + 固定路径）而内容跨 run 变（run_tag 只进
   生成字节不进 URL），无缓存头响应撞 cache key → 跨 run 污染。真实 ModelScope
   URL 带 `Revision=`、HF 带 `resolve/{rev}/` 内容寻址段。
3. **#3 X-Request-ID**：真实 case 还断言重复 ID → 400，旧版没做。

#### 修正清单（已实施）

- **api-stream**：base 改 `http://127.0.0.1:$port`、全部请求裸 curl 去 `-x`
  （对齐 #1/#2/#4 真实形态）→ 撞缓存从机制上消失；新增 X-Request-ID 三断言
  （补齐 #3）：非流式 id endswith `chatcmpl-squid-it-req-42`、流式 chunk id
  endswith `chatcmpl-stream-rid-7` + [DONE]、重复 ID 三连发各响应 200/400 均合法
  （allow_400：并发下取决于重复请求是否赶在首个完成前到达）
- **model-pull**：保持过 squid（对齐 #5 真实代理路径）；mock URL 加 run 唯一
  Revision 路径段（`Revision=$run_tag` / `resolve/$run_tag/`，对齐真实内容寻址
  URL）；热复拉改拉冷拉同 URL（旧版用冷拉从未拉过的 `/models/…` 路径——同 run
  内必 MISS，观测到的"命中"全是跨 run 污染）
- **wait_origin**：127.0.0.1 直连探活（对齐 #1）——探活是脚手架不是被测流量，
  直连才不会被 squid 陈旧缓存条目假阳性

### container 层追加检查

| 阶段 | 面 | 场景 | 判定 |
|---|---|---|---|
| `ca-trust` | F4 | 容器内系统信任库是否含 squid CA（`update-ca-trust`/`update-ca-certificates`/raw bundle 三条路径之一生效） | 校验 openssl 验证链无错=PASS |

### parity 组（透明重写同构校验，源自 no-mirror-test tool-17 全量移植）

gy-006 的 squid 启用 `url_rewrite_program`：客户端零镜像配置，官方 URL 服务端透明
重写到镜像站。该组在 runner 层单独跑（重写是 squid 服务端行为，与客户端环境无关，
无需容器层重复）。**内容签名层**判定（runner 不挂 squid-config CM，helper 断言层
不可用——R13 环境边界）；脚本内唯一显式镜像 URL 是负样本（R14）。

**重写策略自适应**（R12 范围注记）：镜像重写是 CN 出口集群的策略；HK 等海外
出口集群直连 origin 更快，**不配置重写属正常**。parity 用 crates `config.json`
的 `api/v1/crates`（唯一无歧义的镜像特征，origin 上不存在）自探测本集群策略：

- `rewrite`（CN）：`crates-config-guard` 正向断言——镜像特征必须在（模板漂移报警位，R15）
- `direct`（HK）：`crates-config-guard` 反向断言——镜像特征必须**缺席**（谁错误地
  给海外集群加了重写照样红）；其余检查点保持正向（验证直连内容完整性，魔数/共享
  签名对 origin 同样成立）

| 检查点 | 规则 | 判定（状态码 + 魔数/内容签名） |
|---|---|---|
| pypi-simple / pypi-packages（动态取真实 wheel） | 规则1/12：索引页 + files.pythonhosted 对象域 | 200/206 + 相对路径或官方 URL |
| gh-archive / gh-release / gh-raw | 规则3/13：gh-proxy 前缀式 | gzip 魔数 `1f8b08` / ELF 魔数 `7f454c46` / 200 |
| goproxy-list / go-tarball / go-json | 规则5：goproxy.cn 同构 / aliyun tarball / `?mode=json` 分流 | `^v` / gzip / `"` version` JSON（tool-18 事故回归位，R15） |
| ubuntu-release / ports-release | 规则6：apt host 交换 | `Origin: Ubuntu` |
| npm-doc / npm-tgz | 规则7：registry.npmmirror host 交换 | `"versions"` / gzip |
| crates-index / crates-config / crates-static | 规则8：rsproxy sparse index | `"vers"` / `api/v1/crates` 模板漂移守卫（R15，**策略自适应**：rewrite 正向 / direct 反向）/ gzip |
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
| `actions-channels` | Actions 构件上传/下载通道 A/B 对照各 5 次：`productionresultssa3.blob.core.windows.net`（Azure blob 下载）、`results-receiver.actions.githubusercontent.com`（CreateArtifact 上传）；走 squid 与直连（剥代理 env）各 5 次 | 可达=2xx–4xx 应答（未认证 4xx 属预期；**5xx 不算**——经代理时 5xx 主要是 squid 错误页）。**squid 成功率 ≥ 直连 且 p50 ≤ 直连×1.5 → PASS；squid 比直连差 → FAIL**；直连全败=出口策略封锁，squid 是唯一通路（判 PASS 留档） | R17 A/B |
| `ghproxy-health` | gh-proxy（`GHPROXY_URL`，默认 gh-proxy.test.osinfra.cn）真实拉取 octocat README，A/B 各 5 次（URL 形态对齐 CANN gitconfig insteadOf） | 同 A/B 判定 + **5s 绝对预算兜底**（A/B 相对判定可能双双都慢——同走坏 host，绝对线防漏）；内容抽查非空 | R17 A/B |
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
