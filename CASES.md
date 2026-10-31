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
pkg 组另用 openEuler 24.03 基底镜像（dnf/yum 原生形态，见下文 R20）。

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
| goproxy-list / go-tarball / go-json | 规则5：goproxy.cn 同构 / tarball→dl.google.com / `?mode=json`→golang.google.cn | `^v` / gzip / `"` version` JSON（tool-18 事故回归位，R15） |
| go-json-query / go-json-cn / go-tarball-cn / go-dl-page | 规则5b：`?mode=json` 保留完整 query / 中国镜像入口自我改写规避 / 第二入口 `golang.google.cn/dl/go*` / `/dl/` 下载页边界守卫 | 真 JSON 可解析（`json.load`，2026-09-20 JSONDecodeError 事故形态）/ 真 JSON / gzip `/dl/` 不得命中 `/dl/go*`（200 + HTML） |
| ubuntu-release / ports-release | 规则6：apt host 交换 | `Origin: Ubuntu` |
| npm-doc / npm-tgz | 规则7：registry.npmmirror host 交换 | `"versions"` / gzip |
| crates-index / crates-config / crates-static | 规则8：rsproxy sparse index | `"vers"` / `api/v1/crates` 模板漂移守卫（R15，**策略自适应**：rewrite 正向 / direct 反向）/ gzip |
| conda-cloud / conda-pkgs / miniconda | 规则9：nju `/cloud/` 前缀重映射 | HEAD 200（repodata 百 MB 级只探头） |
| openeuler-repomd | 规则10：yum host 交换 | `<repomd` |
| rustup-manifest / rustup-init | 规则10a：huaweicloud 固定映射 | `manifest-version` / HEAD 200 |
| NEG conda-nocloud（故意错映射，直连镜像） | R14 负样本 | 期望 404/403：证明判定方法有效 |

### tools 组（真实工具链 e2e：no-mirror 移植 + 上游仓库 CI 现状复刻）

两个并存维度，判定口径分开：
1. **no-mirror 形态**（R16 移植）：业务命令零镜像配置，加速只靠 squid 服务端重写；
2. **真实 CI 现状复刻**（2026-10-20 增补）：按 `projects/*` 上游仓库 workflow 的实际写法
   原样执行——含显式 `HF_ENDPOINT=hf-mirror.com`、`download.pytorch.org` 索引等。
   该维度只回答"这些仓库的真实流量经 squid 是否可用"，不参与 R12 no-mirror 判定。

工具链缺失记 SKIP（数据），在而失败记 FAIL。`HEAVY=1` 追加编译/工具链级重场景与
torch wheel 全量下载。runner 与 CANN 容器层各跑一遍。

| 阶段 | 对应原用例 | 场景 | 规则 |
|---|---|---|---|
| `tool-pip` | tool-01 | pip 官方 index 下载→安装→import（极简 runner 缺 pip 时 ensurepip/apt 兜底，兜底本身也是真实 apt 链路） | R12、R13 |
| `tool-apt` | tool-02 | 官方源零换源 `apt-get update && install jq` | 规则6 |
| `tool-npm` / `tool-pnpm` | tool-09/15 | 默认 registry 安装 express / bootstrap pnpm 后安装 | 规则7 |
| `tool-uv` | tool-12 | pip bootstrap uv + uv pip install | 规则1 |
| `tool-torch` | —（上游仓库增补） | `download.pytorch.org/whl/cpu` 索引可达 + 版本解析；`HEAVY=1` 全量下载 torch wheel 并校验 ZIP 魔数（规则11：pytorch 官方源不重写，经 squid 直通） | 规则11、R13 |
| `tool-goproxy` | tool-04 | go 缺失时官方 tarball bootstrap（squid 大文件下载）+ `go mod download` | 规则5 |
| `tool-wget` | tool-06 | 官方 github release wget + ELF 魔数 | 规则3 |
| `tool-gitlfs` | tool-14 | git-lfs 官方 release bootstrap（curl，极简镜像无 wget） | 规则3 |
| `tool-modelscope` | —（vllm-ascend/sglang 增补） | modelscope CLI 双通道：model `Qwen/Qwen2.5-0.5B` config + dataset `vllm-ascend/gsm8k-lite`（jsonl 首行 JSON 校验） | R12 |
| `tool-hf` | —（sglang NPU CI 复刻） | `hf download` + `HF_ENDPOINT=hf-mirror.com`（`HF_HUB_DISABLE_XET=1` 对齐镜像 HTTP 回落） | 真实 CI 复刻（不参与 R12） |
| `tool-git` | tool-03 | github.com 直连 clone（runner 层 no-mirror 形态；容器层 insteadOf 走 gh-proxy，两形态都记录） | R12 |
| `tool-rustup`（heavy） | tool-19 | sh.rustup.rs bootstrap + cargo serde 构建 | 规则10a、8 |
| `tool-conda`（heavy） | tool-11 | miniconda 官方 installer + conda-forge numpy | 规则9 |
| `tool-cmake`（heavy） | tool-07 | googletest 直连 clone + cmake 构建 | R12 |
| `tool-bazel`（heavy） | tool-08 | bazelisk（官方 release）+ bazel_dep 构建 | 规则3 |
| `tool-precommit`（heavy） | tool-18 | pre-commit + gitleaks 官方 hook repo | 规则3 |

排除留档（R16）：tool-16 yum 已由 pkg 组在 openEuler 基底容器补齐（R20）；
tool-17 docker-pull 与 tool-20 buildkit（需 docker/buildkitd 服务端，机制不同归 e2e 平台测试）。
obsutil（triton-ascend OBS CLI）按用户决定暂不纳入（2026-10-20）。

### pkg 组（dnf/yum，R20，容器层 openEuler 24.03 only）

镜像：`swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/openeuler/openeuler:24.03`
（openEuler 24.03 LTS-SP3，amd64/arm64 多 arch）。dnf/yum 的源解析、metalink、
GPG 校验与 RPM 事务无法用 curl 模拟，只能在原生基底真实执行；runner 与 CANN
镜像均 ubuntu，故本组只挂一个容器层 job。镜像不带 git，job 首步用 dnf 装
`git-core` 引导 checkout（这一步本身就是真实 dnf 安装链路）。

| 阶段 | 场景 | 判定 | 规则 |
|---|---|---|---|
| `ca-trust` | 容器内系统信任库是否含 squid CA（此处走 RHEL 路径：anchors + `update-ca-trust extract`） | curl 无 `-k` 验证通过=PASS | F4、R20 |
| `pkg-dnf` | `dnf makecache` + `dnf install tree`（repo 限定 OS/everything/EPOL/update，源 URL 保持镜像默认） | 两条命令均 0 退出 + `tree --version` 可执行 | 规则10、R20 |
| `pkg-yum` | `yum install jq`（openEuler 24.03 的 yum 为 dnf 别名，仍验证入口语义） | 0 退出 + `jq --version` 可执行 | 规则10、R20 |

两层口径注记：`pkg-dnf`/`pkg-yum` 在 runner 层与 CANN 容器层记 SKIP（无 dnf，
R16 数据留档），只有本组为真实执行——即套件里**唯一覆盖 RHEL 系 CA 信任路径**
（不经 CA 环境变量，dnf/librepo 只认系统 trust store）的样本。

### upstream 组（上游通道健康，R17，runner 层 only）

源自 cn12-001 runbook 诊断（2026-10-08）：单 pod 6h 内 17 次 TIMEDOUT，53% 集中在
GitHub Actions 构件通道（出口固有抖动，代理侧不可修）；gh-proxy test 实例 4 次
超时且实测 p50 3.2s（配置选择问题，可修）。本组把诊断判据固化为自动化测试——
**单次失败仅记录，单域集中失败才 FAIL**（对齐告警降噪口径 `sum by (host) > 3`）。

> 范围收窄（2026-10-13）：原 `actions-channels` 阶段（blob/results-receiver
> 两域 A/B）已移除——两域入 NO_PROXY（PR 1926/1930）后生产流量直连不过
> squid，A/B 的"squid 腿"靠 env 代理同样直连，相对判定退化为两条直连腿的
> 抖动互搏（gy-001/gy-004 假红实证）。不测不过 squid 的流量。

| 阶段 | 场景 | 判定 | 规则 |
|---|---|---|---|
| `ghproxy-health` | gh-proxy（`GHPROXY_URL`，默认 gh-proxy.test.osinfra.cn）真实拉取 octocat README，A/B 各 5 次（URL 形态对齐 CANN gitconfig insteadOf） | 同 A/B 判定 + **5s 绝对预算兜底**（A/B 相对判定可能双双都慢——同走坏 host，绝对线防漏）；内容抽查非空 | R17 A/B |
| `slow-upstream` | 静默上游：本机 python 监听 accept 后不响应，`-x` 强制走 squid 测 read_timeout 实际形态 | 仅数据留档不判结论（CI 时限内无法观测 30min 超时；若 squid 短超时内回 504 说明 fail-fast 已生效） | R17 |

runner 层 only 的原因：gh-proxy 是 runner 环境关心的事，与执行层
（容器 CA/工具链）无关。

### imagebuild 组（镜像构建网络模拟，R18，runner + 容器两层）

背景（2026-10-14）：vllm-ascend 的 Image Build and Push（_schedule_image_build.yaml
+ Dockerfile.310p）是 runner 集群上最重的真实外网负载之一，出网面里过 squid 的
有四路——catlass 子模块（gitcode.com）、cmake 第三方压缩包
（gitcode.com/cann-src-third-party，`COMPILE_CUSTOM_KERNELS=1` 即 csrc 缓存
miss 时触发）、GIT_PROXY 形态 clone vllm（github.com 经 gh-proxy insteadOf
重写）、CANN/OBS 静态资产（`ascend-repo.obs` 安装包 + CI 工件桶，2026-10-20
增补）。本组用真实 commit/tag/REQ_URL/对象键复刻这四路（外网面全量口径）；
集群内 cache-service（pypi/yum/rustup/crates）已入 NO_PROXY 直连，不测不过
squid 的流量。

| 阶段 | 场景 | 判定 | 规则 |
|---|---|---|---|
| `ib-catlass` | `git fetch --depth 1` 固定 commit（`CATLASS_COMMIT`，.gitmodules pinned）拉 gitcode.com/cann/catlass（checkout submodules:recursive 形态） | fetch 成功 + 工作区内容落盘（>10 文件）；pinned commit 被托管端拒绝时回退默认分支 depth1（⚠️ 降级数据点，不判失败） | R18 |
| `ib-tarballs` | cmake REQ_URL 5 个 release 压缩包（abseil-cpp/protobuf/googletest/json/makeself）两遍拉取；明细落 probes.tsv + imagebuild-cache.tsv | 两遍均 2xx + sha256 一致（缓存内容完整性）；Cache-Status 仅留档不判结论（可缓存性取决于 refresh_pattern） | R18 |
| `ib-vllm-gitproxy` | gitconfig `url.<GIT_PROXY>https://github.com/.insteadOf` + `clone --depth 1 -b <tag>`（Dockerfile L86/L92 形态，大 pack 吞吐）；tag 预检不存在自动取最新 tag | clone 成功 + 工作区 >100 文件 | R18 |
| `ib-ascend-obs` | myhuaweicloud OBS 静态资产四类：CANN toolkit `.run`（带 `Referer` 防盗链，Range 32B + HEAD Content-Length）、CI 覆盖率 JSON（Range 首字节）、覆盖率 `outputs.tar.gz`（gzip 魔数；`HEAVY=1` 两遍全量 sha256）、gitleaks 单文件 ELF（`wget --no-check-certificate` 形态，下载后执行 `version`） | Range 必须 206 且魔数正确（`#!` / `{` / `1f8b08` / `7f454c46`）；CANN 包 Content-Length >100MB；HEAVY 两遍 sha256 一致；负样本不存在 key 必须 403/404（R3）；`X-Cache-Lookup`/`Via` 仅留档不判 HIT | R18、R3、F6 |

两层口径：真实构建里 catlass checkout 发生在 runner workspace（build 之前）、
cmake 拉包、OBS 资产下载与 vllm clone 发生在 build 容器内——runner 层验链路，
容器层验「镜像内 gitconfig insteadOf（环境正道）+ CA 信任路径」下四路全通，其中
`ib-vllm-gitproxy` 在容器层与真实构建执行环境一致。参数可覆盖：
`CATLASS_COMMIT` / `IB_GIT_PROXY` / `IB_VLLM_REF` / `OBS_CANN_URL` /
`OBS_CANN_REFERER` / `OBS_COV_JSON` / `OBS_COV_TGZ` / `OBS_ELF_URL` /
`OBS_NEG_URL`（`IB_GIT_PROXY` 置空 = 直连，本地冒烟逃生门）。重写 helper 无
OBS 分支（规则 11 把 OBS 划入不重写范围），实际命中规则 12「白名单外原样放行」；
`acl registry` 仅含 `swr.*` 等镜像仓库域，故 OBS 域名走 `ssl_bump bump all`——
该阶段是**经 squid MITM 解密但不重写**的样本，不是不过 squid 的直连。

### cabundle 组（no_proxy × CA 注入矩阵，R19，runner + 容器两层）

背景（2026-10-16）：runner pod env 同时注入 no_proxy（构件通道/broker 域名
直连）与 6 个 CA 变量（全指向 /etc/squid-ca/squid-ca.pem）。两类注入各自
正确、组合却可能断裂：排他 CAfile 语义的工具（curl/git/requests/pip）在
直连腿只信 squid-ca.pem 一个文件——它必须同时含 squid CA（MITM 腿）与
公共根（直连腿），即 bundle 形态。

| 阶段 | 场景 | 判定 | 规则 |
|---|---|---|---|
| `cabundle-matrix` | 独立脚本 `no-proxy-ca-test.sh`：① CA 文件数证书张数（1 张=纯 squid CA / ≥2 张=bundle）；② no_proxy 生效性（api.github.com 出网无 CONNECT 行）；③ 直连腿（curl/s_client/requests/node，公共 CA 证书）+ 经 squid 腿（curl/git/requests/pip，MITM 重签）；④ **kubectl（Go 客户端）× 172.16.0.0/12**：mock kubeconfig 指向该网段内伪 API server，本地"记账代理"观测是否发 CONNECT（公网地址作正样本）；⑤ **新增直连域生效性**（PR ascend-ci-deployment#2194 首批）：云元数据端点（100.100.100.200 / 169.254.169.254 / metadata.google.internal）+ 不可缓存 LLM 统计/API 域（stats.vllm.ai / api.siliconflow.cn / api.deepseek.com），用 `curl -v` 是否打印 `Uses proxy env variable` 判定实际绕行代理（不依赖真实出网） | 任一 TLS-FAIL → FAIL（直连红=排他变量挤掉公共根，squid-ca.pem 需换 bundle；代理红=MITM 信任断裂）；NO_PROXY 已声明 172.16.0.0/12 但 kubectl 仍发 CONNECT → FAIL（内网请求会被 squid 接走）；NO_PROXY 已声明新增直连域却仍走代理 → FAIL（不可缓存流量被 squid 接走）；未纳入本批的域 SKIP（`NP_DOMAIN_STRICT=1` 时改判红）；OTHER-ERR（网络/协议层）与 SKIP（工具缺失，如镜像无 node）记录不判红 | R19 |

本地冒烟：`CA=/etc/ssl/certs/ca-certificates.crt bash test-squid/no-proxy-ca-test.sh`
（本机无 squid-ca.pem，用系统 bundle 验脚本逻辑；无代理 env 时 proxy 腿 SKIP）。

工具 bootstrap：极简 runner 镜像缺 requests/pip/node 时矩阵开头 apt 临时补装
（job 级不污染镜像，失败静默 SKIP）。2026-10-16 首轮实证（run 38866669159）：
- runner 层全绿是"SKIP 躲过 requests"的假绿——curl 8.5.0 对 SSL_CERT_FILE 走
  file∪dir union（dir 兜底公共根）所以 curl-direct OK，但 requests/node/pip 全缺
- 容器层（CANN，工具链齐全）**实爆**：`requests-direct` TLS-FAIL（排他
  REQUESTS_CA_BUNDLE + 纯 squid CA + no_proxy 直连），同格 requests-proxy OK
  ——直连红 MITM 绿，坐实"纯 squid CA 挤掉公共根"
- 根修方向：平台侧把 `squid-ca.pem` 换成 bundle（squid CA + 公共根拼接），
  让排他/union/追加三种语义全部自洽；runner 层 bootstrap 装齐后同格预期同红

### gitcode 组（缓存后端，R21，容器层 opt-in）

触发：`gh workflow run test-squid.yaml --ref main -f runner='["<label>"]' -f gitcode=1`
（仅 `workflow_dispatch` 且 `gitcode=1` 时运行，常规 run 不含该 job）。
必须容器层：`insteadOf` 由 job pod 模板的 postStart 写入 `/root/.gitconfig`，
runner 容器没有这条重写。

两种后端（`-f gitcode_backend=`）：

| 后端 | 集群/runner | 重写目标 |
|---|---|---|
| `smart-git-proxy`（默认） | gy-005 `linux-amd64-cpu-8-gy005`（PR #2236） | `http://smart-git-proxy-service.smart-git-proxy.svc.cluster.local:8080/gitcode.com/` |
| `git-cdn-gitcode` | gy-006 `linux-aarch64-cpu-2-gitcdn-test`（仓库 vllm-ascend，PR #2237）及已完成改造的生产集群 | `http://git-cdn-service.git-cdn-gitcode.svc.cluster.local:8000/` |

脚本不硬编码 `/gitcode.com` 前缀段：从 `git ls-remote --get-url` 展开结果剥掉仓库路径反推基址，
因此两种形态共用一套断言。`-f gitcode_direct=1` 跳过重写断言、直接打后端基址，
用于目标 runner 无法派发（如 vllm-ascend 的 Actions 被禁用）时验证**缓存服务本身**。

| 阶段 | 内容 | 判定 | 规则 |
|---|---|---|---|
| `gitcode-config` | 打印全局 `url.*.insteadOf`，用 `git ls-remote --get-url` 展开目标 URL 并反推基址 | 基址 == `GITCODE_PROXY` = PASS；未重写/指向本机 = FAIL（`GITCODE_STRICT=1`，job 固定开启）；`GITCODE_DIRECT=1` 时只留档 | R21 |
| `gitcode-refs-probe` | 对 `<base>/<repo>/info/refs?service=git-upload-pack` 连发两次，抓状态码、耗时与缓存类响应头（`Cache-Status`/`X-Cache`/`Age`） | 200 且响应非空 = PASS；不可达 / 非 git 服务 = FAIL | R21 |
| `gitcode-clone-hitmiss` | 同一 gitcode 仓库 `git clone --depth 1` 两遍，`GIT_TRACE_CURL` 取证实际对端主机 | 两遍成功且 trace 含后端主机 = 路由 PASS；二遍命中缓存头 / 耗时 ≤70% / 两遍均 ≤5s 任一成立 = 缓存 PASS；否则 FAIL | R21 |

说明：该链路属 `.svc.cluster.local`（在 NO_PROXY 内）直连，**不经过 squid**，
故本组不跑 `meta-trace`；结论只代表缓存后端（smart git proxy / git-cdn）的行为。

### stale-index 组（索引页陈旧复现，R15 回归守卫，runner 层 only，opt-in）

背景（2026-10-29 取证）：triton-ascend 3.6.0.post2 构建在 18:32:58 报
`No matching distribution found`。不是包缺失/网络/源站故障——镜像源 10-28 21:50
已重新生成索引页（8012B，含 post2），但源站响应带 `Cache-Control: max-age=1296000`
（15 天），squid 兜底 `refresh_pattern . 0 0% 0 refresh-ims` 没有 `override-expire`，
源站 max-age 直接生效 → 对象全程判新鲜（`elapsed=0` / `HIER_NONE`），镜像重新生成
索引后最长 15 天内不回源验证；两台副本 cache-0/1 先后换页（19:05/19:33）才自愈，
失败窗口约 1 小时（attempt 1/2 红，attempt 4 绿）。

触发：`gh workflow run test-squid.yaml -f stale_index=1`（仅 workflow_dispatch；
`stale_strict=1` 为默认，验证短 TTL 规则是否落地）。

| 阶段 | 场景 | 判定 |
|---|---|---|
| `stale-index-mechanism` | 自带 mock origin：索引页带 15 天 max-age；同 URL（run 唯一 query）经 squid 预热 → 源站翻页（新增 8 条 `3.6.0.post2`）→ 再经 squid 连打 | **仅机制证据，不判红**：翻页后仍供旧页打印 ⚠️（证明"长 max-age 源站缺乏通用保护"的形态），全部新页打印 ℹ️；无代理 env / 无 squid 痕迹 = SKIP |
| `stale-index-cacheability` | 真实域索引页**两种形态**经 squid 连打：① 裸 URL（真实 pip 形态）×4；② 唯一 query `?__idx_query=<run>` ×2 | **主判定**：任一发由缓存对象作答（`hit` / `fwd=stale` / Vary `mismatch`）= **FAIL**（可变索引页被缓存，即事故温床）；全部未落缓存（`miss` / `no-cache`）= PASS；无 squid 痕迹 = SKIP。② 专测 deny 正则是否容忍 query：`^/ascend/repos/.*/$` 在带 query 时 `$` 锚点失配（实测裸 URL 判 `no-cache`、加 `?probe=` 立刻 HIT），正确写法 `^/ascend/repos/[^?]*/(\?.*)?$`（对 `.whl` 不匹配，不伤大对象缓存） |
| `stale-index-origin-parity` | 真实索引页（`STALE_INDEX_URL`，默认 mirrors triton-ascend）经 squid vs 源站直连（cache-buster + no-cache）的 href 清单对照，留档 `Cache-Control`/`Age`/`Cache-Status`/`Last-Modified` | 清单不一致 = **FAIL**（18:32:58 形态，打印源站独有/缓存独有版本）；HIT 且 `Age > STALE_MAX_AGE_S`（默认 900s）=`STALE_STRICT=1` 时 FAIL（短 TTL 未生效）；无 squid 痕迹/源站不可达 = SKIP |

⚠️ `stale-index-mechanism` 用的是 pod IP，**不匹配** `cache deny` 的 `hc_repo dstdomain`（只匹配 `mirrors/repo.huaweicloud.com`），所以它永远看不到域级修复、只作机制证据；真实域是否修复由 `cacheability`（是否被缓存）+ `origin-parity`（清单是否一致）判定。

修复方向留档（配置侧；gy-006 已落地 `cache deny` 版本）：

```conf
# 现行做法（推荐）：可变索引页不落盘，每次回源
acl hc_repo dstdomain repo.huaweicloud.com mirrors.huaweicloud.com
acl mutable_meta urlpath_regex -i ^/(ubuntu|ubuntu-ports)/dists/ ^/openeuler/.*/repodata/ ^/ascend/repos/.*/$
cache deny hc_repo mutable_meta

# 早期建议（refresh_pattern 不能压制源站显式 max-age，已被上面方案取代）
# refresh_pattern -i (mirrors|repo)\.huaweicloud\.com/ascend/repos/pypi/ 0 20% 10 ignore-reload override-expire
```

只约束 Ascend/devcloud 的**索引页**路径，不影响同域 `.whl` 大对象缓存收益。

本地冒烟（无 squid，三阶段均记 SKIP，只验脚本逻辑）：

```bash
RESULTS=/tmp/stale-index bash test-squid/repro-stale-index.sh mock
RESULTS=/tmp/stale-index bash test-squid/repro-stale-index.sh cacheability
RESULTS=/tmp/stale-index bash test-squid/repro-stale-index.sh parity
```

### pip-metadata 组（PEP 658 metadata 不缓存，R22 回归守卫，runner 层 only，opt-in）

背景（2026-10-31 pip hash 校验事故）：`download-r2.pytorch.org` 等 CDN 按
`Accept-Encoding` 实际压缩，但响应**不带 `Vary`**；squid 存储副本无 Vary 键，首个
请求者的编码定型并共享给所有客户端（配置里的 `reply_header_replace Vary
Accept-Encoding` 只改回给客户端的响应头，不影响存储副本与缓存键计算）。pip 的
metadata 请求只收 identity 且不解码（`decode_content=False`），拿到 gzip 变体后对
压缩体算 sha256 必挂。metadata 是 KB 级、内容寻址（文件名含版本+平台）、pip 每次验
hash 的对象，缓存收益趋近零，禁缓存后 MISS 回源代价可忽略。命中面是 wheel 与 sdist
的 metadata 后缀（`.whl.metadata` / `.tar.gz.metadata` / `.zip.metadata`，对所有主机
生效），`.whl/.tar.gz/.zip` 本体不以 `.metadata` 结尾，不受影响。

触发：`gh workflow run test-squid.yaml -f pip_metadata=1`（可选
`-f pip_metadata_url=<真实 metadata URL>`；仅 workflow_dispatch）。

| 阶段 | 场景 | 判定 |
|---|---|---|
| `pip-metadata-mock` | 自带 mock origin：metadata 按 `Accept-Encoding` 压缩但不发 `Vary`；run 唯一路径保留三种后缀（deny 规则 host 无关，pod IP 同样命中）。每种后缀 gzip 预热 ×2 → identity ×2；再取 `.whl`/`.tar.gz`/`.zip` 本体 ×2 作负样本 | **主判定**：三种 metadata 任一发由缓存作答（`hit` / `fwd=stale` / Vary `mismatch`）= **FAIL**（编码变体可被共享）；identity 响应体 sha256 必须等于源站 identity 且非 gzip 魔数 `1f8b`/`Content-Encoding: gzip`，否则 **FAIL**（事故核心形态）；三种本体第二发必须各 HIT（负样本守卫：HIT 检测有效 + deny 未误伤大对象），否则 FAIL；无代理/无 squid 痕迹 = SKIP |
| `pip-metadata-real` | 真实域 `.whl.metadata`（默认 torch wheel URL + `.metadata`，`PIP_METADATA_URL` 可覆盖）经 squid 连打 3 发；源站直连（no-cache）取 identity 真值 | 任一发 HIT/`fwd=stale`/`mismatch` = **FAIL**；identity 体与源站 sha256 不一致或 gzip 魔数 = **FAIL**；404 = SKIP（换 URL）；无 squid 痕迹/不可达/多数失败 = SKIP |
| `pip-metadata-client` | 真实 pip（`--dry-run --no-deps --only-binary=:all: -v`，`PIP_INDEX_URL` 默认事故源 `download.pytorch.org/whl/cpu`，`PIP_PKG` 默认 `torch==2.10.0`）走 PEP 658 metadata 解析 | exit 0 = PASS（日志无 metadata 引用打印 ⚠️ 覆盖度注记）；报 hash/sha256/THashMismatch = **FAIL**（事故签名）；索引/网络/版本等非 hash 失败 = SKIP（R17）；pip <22.2 = SKIP |

修复配置（host 无关，wheel/sdist metadata 后缀全覆盖；注意 squid 7 的
`urlpath_regex` 带 query 时 `$` 锚点会失配，真实 pip 的 metadata URL 不带 query，
故按需求保留后缀写法）：

```conf
acl pip_metadata urlpath_regex -i \.(whl|tar\.gz|zip)\.metadata$
cache deny pip_metadata
collapsed_forwarding_access deny pip_metadata
```

本地冒烟（无 squid，三个阶段均记 SKIP，只验脚本逻辑）：

```bash
RESULTS=/tmp/pip-metadata bash test-squid/repro-pip-metadata.sh mock
RESULTS=/tmp/pip-metadata bash test-squid/repro-pip-metadata.sh real
RESULTS=/tmp/pip-metadata bash test-squid/repro-pip-metadata.sh pip
```


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
