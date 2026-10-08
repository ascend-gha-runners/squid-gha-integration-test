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

也可在 GitHub 网页端触发：仓库 → **Actions** → **test-squid** → **Run workflow**。

### 2. 自动触发（pull_request）

修改以下路径的 PR 会自动跑一遍（固定 `linux-amd64-cpu-2, gy-006`）：

- `test-squid/**`（任何测试脚本/mock 改动）
- `.github/workflows/test-squid.yaml`

## 二、前置条件（缺一不可）

1. **runner 注入 squid**：目标 runner set 的 pod 模板必须已注入
   `HTTP(S)_PROXY`/`HTTPS_PROXY` 指向 squid service（`squid-cache.squid.svc:3128`）
   + 挂载并信任 `squid-ca-cert`（MITM）。workflow 内**故意不配任何代理**——
   流量必须由环境注入，这是被测对象本身。
2. **runner group 放行**：runner 所属 group（`openmerlin-guiyang-006-cluster`）
   需允许本仓库（当前已配置）。
3. **仓库 public**：CANN 镜像自带的 gitconfig 会把 github.com 重写到 gh-proxy
   （这是环境正道，保留），public 仓库匿名即可拉取，无需额外凭据。

## 三、job 结构

| job | 内容 |
|---|---|
| `squid 功能测试` | 元自检、基本代理/CONNECT/MITM、域名矩阵、缓存 MISS→HIT、sha256 完整性、失败面、artifact 下载 |
| `squid 并发测试` | 同对象阶梯并发、异对象并发、混合工具并行 |
| `vllm 通信模拟` | ModelScope/HF 双通道模型下载 + OpenAI API 8 并发 SSE（自带 mock origin） |
| `透明重写同构校验` | no-mirror tool-17 全量移植：13 条重写规则内容签名 + 负样本 + 回归守卫（runner 层 only） |
| `上游通道健康` | Actions 构件通道单域集中失败判据 + gh-proxy 延迟预算（p50≤5s）+ read_timeout 数据留档（R17，runner 层 only） |
| `真实工具链 e2e` | 真实客户端工具（pip/apt/npm/uv/go/wget/git-lfs/modelscope/git）零镜像配置跑通；`heavy=1` 追加 rustup/conda/cmake/bazel/precommit |
| `容器层·*（CANN 镜像）` | 以上五组在 `cann:9.0.0-a3-ubuntu22.04-py3.12` 容器里各跑一遍（多验 CA 信任路径） |
| `汇总` | 聚合十 job 结果表到 GITHUB_STEP_SUMMARY |

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
