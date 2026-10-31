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
  **真实 CI 复刻注记（2026-10-20）**：`projects/*` 上游仓库 workflow 本身存在显式
  镜像与特殊官方索引（sglang NPU CI 的 `HF_ENDPOINT=hf-mirror.com`、各仓库的
  `download.pytorch.org/whl/{cpu,xpu}`、`mirrors.aliyun/tuna`）。这些写法在 tools 组
  以「真实 CI 现状复刻」维度原样保留并单独标注，不参与 R12 no-mirror 判定；
  no-mirror 判定仍由 parity 与 tools 的零镜像阶段承担。obsutil（triton-ascend
  OBS CLI）按用户决定暂不纳入。
  **范围注记（2026-10-08 hk-001 实测修正）**：重写是 CN 出口集群的策略；
  HK 等海外出口集群直连 origin 更快，不配置重写属正常。同构校验（R13/R15）
  必须策略自适应：以唯一无歧义的镜像特征（crates `api/v1/crates`）自探测
  rewrite/direct，direct 集群上该守卫位反向断言（镜像特征必须缺席）。
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
  环境不可行的用例（buildkit 需服务端）排除并留档；yum/dnf 改由 openEuler
  基底容器补充验证（见 R20）。
- **R17 上游通道集中失败判据**（2026-10-08，源自 cn12-001 runbook 诊断）：
  零散上游超时（如 GitHub Actions 构件通道 9/17 次）是出口固有抖动，单次探测
  失败不得判 FAIL；判 FAIL 只看**单域集中失败**（同域 N 次探测 ≥2/3 失败，
  对齐告警降噪口径 `sum by (host) > 3`）。通道健康度带延迟预算（gh-proxy
  p50 > 5s 判 FAIL——test 实例 3.2s 已属不健康）。无法在 CI 时限内观测的
  squid 行为（read_timeout 30min）只做数据留档不判结论。
  **A/B 对照判据**（同日增补，用户定标）：同通道走 squid 与直连各 5 次，
  **squid 成功率 ≥ 直连且延迟不劣（p50 ≤ 直连×1.5 噪声容差）→ PASS；
  squid 比直连差 → FAIL**——代理必须证明自己没让链路变差；直连全败
  （出口策略封锁）时 squid 是唯一通路，成功率判定自动满足。
  **范围收窄**（2026-10-13，用户定标"不测不过 squid 的流量"）：Actions
  构件通道两域（productionresultssa3 blob / results-receiver）入 NO_PROXY
  （PR 1926/1930）后生产流量直连不过 squid——A/B 的"squid 腿"靠 env 代理，
  NO_PROXY 命中后同样是直连，相对判定退化为两条直连腿的抖动互搏
  （gy-001/gy-004 同 commit 一红一绿假红实证）。actions-channels 移出套件；
  R17 判据保留于 gh-proxy 通道（不在 NO_PROXY，A/B 仍真实）+ read_timeout 留档。
- **R18 镜像构建外网面复刻**（2026-10-14，源自 vllm-ascend Image Build and Push
  流量归因）：真实镜像构建（Dockerfile.310p）的出网面里，过 squid 的只有三类
  外网流量——① checkout@v7 submodules:recursive 按 .gitmodules 拉
  gitcode.com/cann/catlass（pinned commit）；② COMPILE_CUSTOM_KERNELS=1 时
  csrc cmake 拉 gitcode.com/cann-src-third-party 5 个 release 压缩包（REQ_URL，
  protobuf 两个 cmake 重复出现算一个）；③ Dockerfile L92 经 GIT_PROXY
  insteadOf clone github.com/vllm-project/vllm。mock 复刻这三路真实 URL/commit/
  tag（外网面全量口径）；集群内 cache-service（pypi/yum/rustup/crates）已入
  NO_PROXY 直连，不测不过 squid 的流量（与 R17 收窄同口径）。
  判定：fetch/下载/clone 成功且内容落盘 + tarball 两遍 sha256 一致（缓存内容
  完整性）；Cache-Status 只留档不判结论（静态 release 资产可缓存性取决于
  squid refresh_pattern，是数据点不是断言）。
  两层口径（2026-10-14 增补）：真实构建里 catlass checkout 在 runner workspace
  （build 之前）、cmake 拉包与 vllm clone 在 build 容器内——runner 层验链路，
  容器层验镜像内 gitconfig insteadOf（环境正道）+ CA 信任路径下三路全通。
  **OBS 静态资产增补（2026-10-20）**：镜像构建与 NPU CI 的另一条真实外网面是
  myhuaweicloud OBS 静态对象——CANN toolkit `.run`（`ascend-repo.obs`，脚本带
  `Referer: https://www.hiascend.com/` 防盗链）、CI 覆盖率工件（`sglang-npu.obs`
  / `vllm-ascend.obs` 的 JSON 与 tar.gz）、代码扫描单文件二进制（`gitleaks`，
  CI 用 `wget --no-check-certificate` 拉取后直接执行）。重写 helper 没有 OBS
  分支（规则 11 已把 OBS 明确划入不重写范围），请求命中规则 12 兜底原样放行
  `OK`；同时 `acl registry` 只含 `swr.*` 等镜像仓库域，OBS 域名走
  `ssl_bump bump all` → 属于**经 squid MITM 解密但不重写**的样本（不是不过
  squid 的直连）：验 Range
  语义（206）与 HEAD 元数据不被 bump 破坏、大对象内容魔数正确、单文件 ELF 可执行，
  并按 R3 配一条不存在 key 的负样本（必须 403/404）。OBS 对象是否可缓存仍只
  留档不判结论（同 refresh_pattern 口径）。
- **R19 no_proxy 直连 × CA 注入形态自洽**（2026-10-16，源自平台 CA 注入变量组
  排查）：平台向 pod 注入 6 个 CA 变量（全指向 /etc/squid-ca/squid-ca.pem），
  按工具实现分三类语义——排他 CAfile（CURL_CA_BUNDLE / REQUESTS_CA_BUNDLE /
  GIT_SSL_CAINFO / PIP_CERT，信任集=仅该文件）、库级 default-paths
  （SSL_CERT_FILE，file∪dir 联合、默认 CA 目录仍兜底）、追加
  （NODE_EXTRA_CA_CERTS，不替换内置 Mozilla 根）。风险：no_proxy 命中 →
  流量直连 → 对端是公共 CA 证书，排他变量若指向纯 squid CA（不含公共根）
  则直连 TLS 断裂（curl error 60/77、requests SSLError）——squid 无恙，
  是注入形态问题。唯一自洽形态：squid-ca.pem 为 bundle（squid CA + 公共根
  拼接）。测试三件事：① CA 文件形态取证（数证书张数）；② no_proxy 生效性
  （api.github.com 绕开 squid，无 CONNECT 行）；③ 工具×路径矩阵——直连腿
  （公共证书：curl/s_client/requests/node）+ 经 squid 腿（MITM 重签：
  curl/git/requests/pip）。判定：任一 TLS-FAIL 即红（直连红=公共根被挤出；
  代理红=MITM 信任断裂）；OTHER-ERR/SKIP 记录不判红。
  2026-10-16 本机语义实证：curl 8.22 对 SSL_CERT_FILE 走排他加载（空文件
  error 77、无关证书 error 60，默认 CA 目录不兜底）；openssl s_client 走
  file∪dir union（坏 file 被 dir 兜底仍绿）；node 只追加。
  2026-10-21 增：kubectl（Go net/http 的 ProxyFromEnvironment）单独验证
  172.16.0.0/12——Go 与 curl 各有 no_proxy 解析器，CIDR 命中不能用 curl 代答。
  手段：mock kubeconfig 指向 172.16.255.254:6443（伪 API server），把代理
  换成"记账代理"（收到 CONNECT 即落盘回 502），公网 203.0.113.1 作正样本；
  NO_PROXY 已含该网段却出现 CONNECT 即判红（内网请求会被 squid 接走）。
  注意 kubeconfig 的 user 不能为空：空 user 会让 kubectl 先交互式要
  Username，请求根本没发出（本机实证，必须给 token 占位）。
  kubectl 二进制获取走镜像链：gy-006 上 dl.k8s.io（fastly）出口不通，裸二进制
  拉不动——改从 USTC/NJU 镜像的 pkgs.k8s.io deb 仓库取 `kubectl_<ver>_<arch>.deb`
  （11MB，`dpkg-deb -x` 或 `ar`+`tar` 解出 `/usr/bin/kubectl`），裸二进制源
  （dl.k8s.io / DaoCloud 反代）作兜底；两跳都有逐源日志，CI 日志可直接回答
  "本集群哪个源可用"。
- **R20 dnf/yum 只在原生基底验证**（2026-10-21 增补）：包管理器的源配置、
  metalink 解析、GPG 校验、RPM 事务都不能靠 curl 模拟——必须用 openEuler/
  RHEL 基底镜像真实跑。runner 与 CANN 镜像均 ubuntu，套件内 pkg 阶段按 R16
  记 SKIP；容器层单独一个 openEuler 24.03 job（SWR 华为云副本，多 arch）
  真实执行 dnf/yum。该形态同时是**唯一覆盖 RHEL 系 CA 信任路径**的样本：
  注入脚本走 `/etc/pki/ca-trust/source/anchors` + `update-ca-trust extract`，不经任何 CA 环境变量（dnf/librepo 只认系统 trust store，
  与 Debian 系的 `update-ca-certificates` 分叉）。repo 同步面收窄到 OS/everything/EPOL/
  update 四个源（镜像默认还开 debuginfo/source/update-source，元数据 100MB+
  且与安装无关），源 URL 保持镜像默认（零换源，R16）。
- **R22 PEP 658 metadata 不缓存**（2026-10-31，源自 pip hash 校验事故）：
  编码变体毒化机理——CDN（download-r2.pytorch.org / files.pythonhosted.org /
  repo.huaweicloud.com 等）按 `Accept-Encoding` 实际压缩，但响应不带 `Vary`；
  squid 存储副本无 Vary 键，首个请求者的编码定型并共享给所有客户端
  （`reply_header_replace Vary Accept-Encoding` 只改回给客户端的响应头，不影响
  存储副本与缓存键计算）。pip 的 metadata 请求只收 identity 且**不解码**
  （`decode_content=False`），拿到 gzip 变体后对压缩体算 sha256 必挂。
  wheel 与 sdist 的 metadata 后缀（`.whl.metadata` / `.tar.gz.metadata` /
  `.zip.metadata`）是 KB 级、内容寻址（文件名含版本+平台）、pip 每次验 hash 的
  对象，缓存收益趋近零，因此**禁缓存**（`cache deny` +
  `collapsed_forwarding_access deny`），后缀对所有主机生效；
  `.whl/.tar.gz/.zip` 本体不以 `.metadata` 结尾，不受影响。
  判定三面：① 同 URL 连打不得由缓存作答（`hit` / `fwd=stale` / Vary
  `detail=mismatch` 都算缓存存量）；② identity 响应体 sha256 必须等于源站
  identity，且不得是 gzip 魔数 `1f8b`（事故核心客户端面）；③ 同 host 本体
  二连发必须 `hit`——负样本守卫，证明 HIT 检测方法有效且 deny 未误伤大对象。
  真实域阶段另加 pip `--dry-run --no-deps` 端到端（PEP 658 metadata 解析 +
  hash 校验），hash mismatch 判红，索引/网络/版本原因记 SKIP（R17 口径）。

## 六、与两份前作的关系

| 前作 | 复用什么 | 本套件差异 |
|---|---|---|
| `vllm-benchmarks` wt-test-squid `test-squid/` | mock 载荷原则（R6）、阶段计时 TSV（R7） | 它按"CI 下载/上传链路"组织；本套件按"squid 功能面"组织，新增并发维度 |
| `squid_e2e_tests` no-mirror-test `tool-*.yaml` | 双端证据（access.log 取证）、负样本对照（tool-17）、幂等循环跑批 | 它绑定 gy-006 k8s；本套件核心逻辑 runner 无关，k8s 只是壳之一 |
