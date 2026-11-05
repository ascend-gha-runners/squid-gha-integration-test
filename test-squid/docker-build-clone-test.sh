#!/usr/bin/env bash
# =============================================================================
# docker-build-clone-test.sh —— vllm-ascend Dockerfile 的 git-cdn clone 面验证
#
# 背景（vllm-project/vllm-ascend#20836「Route github.com clones through in-cluster
# git-cdn service」）：镜像构建里的所有 github.com 取数改成显式重写——
#     git -c url."${GIT_CDN_MIRROR}".insteadOf="https://github.com/" clone ...
#     git -c url."${GIT_CDN_MIRROR}".insteadOf="https://github.com/" fetch --depth 1 $REPO $COMMIT
#     git -c url."${MIRROR}".insteadOf=... -c url."${GITCODE_MIRROR}".insteadOf=... \
#         submodule update --init --recursive
# 这些命令跑在构建容器里（不是 job 容器），因此不能用 job 的 /root/.gitconfig，
# 必须靠 -c 内联重写。本脚本按 Dockerfile 的原始形态逐条复刻，两层都跑：
#   runner 层：jenkins/Actions runner 容器（无 /root/.gitconfig 现象）
#   容器层  ：CANN 镜像（pod 模板 postStart 写的 /root/.gitconfig 可见）
# 两条命令都显式带 -c，所以两层的被测行为应当一致 —— 这也顺带证明
# 「PR 的写法不依赖宿主 gitconfig」。
#
# 测试项（逐条对应 Dockerfile 的 RUN 行）：
#   T1 vllm 大仓浅 clone（--depth 1 -b $VLLM_TAG），跑两遍留档缓存收益
#   T2 按 SHA fetch（fetch --depth 1 $VLLM_REPO $VLLM_COMMIT）—— 未同步 SHA 的风险面
#   T3 flash-attention-npu 全量 clone（无 --depth，PR 原样）
#   T4 vllm-ascend 浅 clone + submodule update --init --recursive（github + gitcode 双 mirror）
#
# 判定：
#   T1/T3/T4：rc=0 且产物非空 → PASS；失败 → FAIL（git-cdn 没服务好该对象）
#   T2      ：必须 60s 内明确结束且 rc=0 → PASS；挂死/超时/not our ref → FAIL。
#             先用直连 github 作对照组：对照组失败说明是环境问题 → 本项 SKIP
#   git-cdn 不可达 → 整脚本 SKIP（exit 2，两层都可能出现，不误红）
#
# 依赖：集群内 DNS（*.svc.cluster.local）；不需要 token（这些仓库 public）
#
# 用法：bash test-squid/docker-build-clone-test.sh
#
# 可覆盖：
#   GIT_CDN_MIRROR / GIT_CDN_GITCODE_MIRROR   mirror 基址
#   VLLM_REPO / VLLM_TAG / VLLM_COMMIT        vllm 取数参数
#   WORKDIR                                   工作目录（默认 mktemp）
#   RESULTS                                   证据目录
#
# 退出码：0=全部 PASS；1=有 FAIL；2=SKIP
# =============================================================================
set -uo pipefail

MIRROR="${GIT_CDN_MIRROR:-http://git-cdn-service.git-cdn.svc.cluster.local:8000/}"
GITCODE_MIRROR="${GIT_CDN_GITCODE_MIRROR:-http://git-cdn-service.git-cdn-gitcode.svc.cluster.local:8000/}"
VLLM_REPO="${VLLM_REPO:-https://github.com/vllm-project/vllm.git}"
VLLM_TAG="${VLLM_TAG:-v0.32.0}"
VLLM_COMMIT="${VLLM_COMMIT:-24420b7a341af37a9bc3186e6fc6062512e0aa58}"
FLASH_REPO="https://github.com/MinghuasLab/flash-attention-npu.git"
ASCEND_REPO="https://github.com/vllm-project/vllm-ascend.git"

RESULTS="${RESULTS:-${RESULTS_DIR:-/tmp/dockerbuild-clone}}"
mkdir -p "$RESULTS"
TSV="$RESULTS/dockerbuild-clone.tsv"
: >"$TSV"

WORK="${WORKDIR:-$(mktemp -d)}"
mkdir -p "$WORK"
log() { echo "[$(date '+%H:%M:%S')] $*"; }
record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$TSV"; }
FAILED=0

# 重写参数：完全复刻 Dockerfile 里的 -c 形态。用数组而不是 shell 函数，
# 因为 timeout(1) 只能 exec 外部命令，不能调用函数（rc=127）。
CDN_CFG=(-c "url.$MIRROR.insteadOf=https://github.com/")
BOTH_CFG=("${CDN_CFG[@]}" -c "url.$GITCODE_MIRROR.insteadOf=https://gitcode.com/")

# ---- T0：前置取证 + mirror 可达性 -------------------------------------------
log "=== T0 前置取证 ==="
{
    echo "id=$(id -u) user=$(id -un) HOME=${HOME:-<空>}"
    echo "mirror=$MIRROR"
    echo "gitcode_mirror=$GITCODE_MIRROR"
    ls -l /root/.gitconfig /etc/gitconfig 2>&1 || true
    echo "--- git 可见 url.* ---"
    git config --show-origin --get-regexp '^url\.' 2>&1 || echo '(空)'
} | tee "$RESULTS/precheck.txt"

code=$(curl -sS -m 6 -o "$RESULTS/mirror-root.body" -w '%{http_code}' "$MIRROR" 2>/dev/null || echo ERR)
log "mirror root -> $code"
if [ "$code" != "200" ]; then
    log "⚠️ git-cdn 不可达（$code）→ SKIP（非失败）"
    record precheck 0 SKIP "mirror=$code"
    exit 2
fi
record precheck 0 PASS "mirror=$code"

# ---- T1：vllm 大仓浅 clone（PR 原样命令），跑两遍 ----------------------------
log "=== T1 vllm 浅 clone（--depth 1 -b $VLLM_TAG）==="
clone_once() {
    local dest="$1" logf="$2" start sec rc
    start=$(date +%s)
    GIT_TERMINAL_PROMPT=0 timeout 420 \
        git "${CDN_CFG[@]}" clone --depth 1 -b "$VLLM_TAG" "$VLLM_REPO" "$dest" >"$logf" 2>&1
    rc=$?
    sec=$(( $(date +%s) - start ))
    echo "$rc $sec"
}
read -r rc1 sec1 <<<"$(clone_once "$WORK/vllm1" "$RESULTS/vllm-clone-1.log")"
log "① rc=$rc1 ${sec1}s"
read -r rc2 sec2 <<<"$(clone_once "$WORK/vllm2" "$RESULTS/vllm-clone-2.log")"
log "② rc=$rc2 ${sec2}s（缓存收益留档，不判红）"
rm -rf "$WORK/vllm2"
if [ "$rc1" -eq 0 ] && [ -d "$WORK/vllm1/.git" ]; then
    record vllm-clone "$sec1" PASS "r1=${sec1}s r2=${sec2}s"
else
    record vllm-clone "$sec1" FAIL "rc=$rc1"
    grep -aE 'fatal:|not our ref|error|Could not resolve' "$RESULTS/vllm-clone-1.log" | head -5
    FAILED=1
fi
rm -rf "$WORK/vllm1"

# ---- T2：按 SHA fetch（未同步 SHA 风险面） ----------------------------------
log "=== T2 按 SHA fetch（$VLLM_COMMIT）==="
direct_rc=1
{
    d="$WORK/vllm-direct"; mkdir -p "$d"; git -C "$d" init -q
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0 \
        timeout 90 git -C "$d" fetch --no-tags --depth=1 "$VLLM_REPO" "$VLLM_COMMIT" \
        >"$RESULTS/fetch-sha-direct.log" 2>&1
    echo $?
} >"$RESULTS/fetch-sha-direct.rc"
direct_rc=$(cat "$RESULTS/fetch-sha-direct.rc")
log "对照组（直连 github.com 剥掉重写）rc=$direct_rc"

start=$(date +%s)
{
    t="$WORK/vllm-sha"; mkdir -p "$t"; git -C "$t" init -q
    GIT_TERMINAL_PROMPT=0 timeout 60 \
        git "${CDN_CFG[@]}" -C "$t" fetch --no-tags --depth=1 "$VLLM_REPO" "$VLLM_COMMIT" \
        >"$RESULTS/fetch-sha-cdn.log" 2>&1
    echo $?
} >"$RESULTS/fetch-sha-cdn.rc"
rc_sha=$(cat "$RESULTS/fetch-sha-cdn.rc")
sec_sha=$(( $(date +%s) - start ))
log "被测面（经 git-cdn）rc=$rc_sha ${sec_sha}s"
tail -3 "$RESULTS/fetch-sha-cdn.log" | sed 's/^/    | /'
if [ "$direct_rc" -ne 0 ]; then
    log "⚠️ 对照组也失败 → 环境问题，T2 记 SKIP"
    record fetch-sha "$sec_sha" SKIP "direct_rc=$direct_rc"
elif [ "$rc_sha" -eq 0 ]; then
    record fetch-sha "$sec_sha" PASS "rc=0"
else
    record fetch-sha "$sec_sha" FAIL "rc=$rc_sha(124=超时) direct_rc=0"
    FAILED=1
fi

# ---- T3：flash-attention-npu 全量 clone（无 --depth） ------------------------
log "=== T3 flash-attention-npu 全量 clone ==="
start=$(date +%s)
GIT_TERMINAL_PROMPT=0 timeout 420 \
    git "${CDN_CFG[@]}" clone "$FLASH_REPO" "$WORK/flash-attention-npu" >"$RESULTS/flash-clone.log" 2>&1
rc_fl=$?
sec_fl=$(( $(date +%s) - start ))
log "rc=$rc_fl ${sec_fl}s"
if [ "$rc_fl" -eq 0 ] && [ -d "$WORK/flash-attention-npu/.git" ]; then
    record flash-clone "$sec_fl" PASS ""
else
    record flash-clone "$sec_fl" FAIL "rc=$rc_fl"
    grep -aE 'fatal:|not our ref|error|Could not resolve' "$RESULTS/flash-clone.log" | head -5
    FAILED=1
fi
rm -rf "$WORK/flash-attention-npu"

# ---- T4：vllm-ascend 浅 clone + submodule 双 mirror -------------------------
log "=== T4 submodule（github + gitcode 双 mirror）==="
start=$(date +%s)
GIT_TERMINAL_PROMPT=0 timeout 300 \
    git "${CDN_CFG[@]}" clone --depth 1 "$ASCEND_REPO" "$WORK/vllm-ascend" >"$RESULTS/ascend-clone.log" 2>&1
rc_cl=$?
if [ "$rc_cl" -eq 0 ]; then
    GIT_TERMINAL_PROMPT=0 timeout 300 \
        git "${BOTH_CFG[@]}" -C "$WORK/vllm-ascend" submodule update --init --recursive \
        >"$RESULTS/submodule.log" 2>&1
    rc_sub=$?
else
    rc_sub=1
fi
sec_sub=$(( $(date +%s) - start ))
log "clone rc=$rc_cl submodule rc=$rc_sub ${sec_sub}s"
if [ "$rc_cl" -eq 0 ] && [ "$rc_sub" -eq 0 ] && [ -n "$(ls -A "$WORK/vllm-ascend/csrc/third_party/catlass" 2>/dev/null)" ]; then
    record submodule "$sec_sub" PASS "catlass 已检出"
else
    record submodule "$sec_sub" FAIL "clone_rc=$rc_cl submodule_rc=$rc_sub"
    grep -aE 'fatal:|not our ref|error|Could not resolve' "$RESULTS/submodule.log" 2>/dev/null | head -5
    FAILED=1
fi

# ---- 汇总 -------------------------------------------------------------------
echo
log "=== 汇总（$TSV）==="
cat "$TSV"
[ "$FAILED" -eq 0 ] && { log "全部 PASS"; exit 0; }
log "存在 FAIL：git-cdn 未能服务 Dockerfile 所需的 git 对象"
exit 1
