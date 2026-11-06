#!/usr/bin/env bash
# =============================================================================
# repro-git-302.sh —— git 远端命令 × squid 302 → git-cdn 矩阵（gy-006）
#
# 背景：PR #2470 起 squid 不再对 github.com 做前缀式 body 重写，而是对
#   /<owner>/<repo>(.git)?/info/refs?service=git-upload-pack 的初始 GET 返回
#   302，Location 指向集群内 git-cdn。parity 规则13 与 imagebuild 的 vllm clone
#   只覆盖了「clone --depth 1」一种形态；本脚本补齐常见远端 git 命令，回答
#   「302 策略是否对所有 git 客户端形态都成立」。
#
# 覆盖：
#   A. 302 契约（curl，不跟随跳转）
#      - upload-pack（带/不带 .git 后缀、两个不同仓库）
#      - receive-pack（push 形态，只留档：200=不受缓存影响，302 git-cdn=需确认）
#      - HEAD 方法 / 无 service query
#      - 负样本：archive tar.gz、仓库 HTML 页不得跳 git-cdn
#   B. 真实 git 命令（剥掉宿主机 insteadOf，请求原样打到 github.com）
#      - ls-remote：plain / --heads --tags / --symref / 指定 ref / protocol v0、v2
#      - clone：full / --depth 1 / --filter=blob:none / --single-branch / --bare
#      - fetch：--tags / --prune / --deepen / --unshallow
#      - pull --ff-only、remote show、remote update
#      - 按 SHA fetch（actions/checkout 形态）
#      - http.followRedirects=false 反证（必须失败，证明 302 真实存在）
#   - 默认 SKIP：push（需写权限，用环境变量打开）
#
# 判定：
#   - 真实命令 must rc=0 且 stderr 出现 `redirecting to ...git-cdn`
#   - 契约探头 must 302 且 Location 命中 git-cdn 且路径/查询串保留
#   - 负样本 must 不跳 git-cdn
#   - submodule：clone 后 `git submodule status` 必须非空（子模块真的被拉下来）
#   - LFS：clone 用 GIT_LFS_SKIP_SMUDGE=1（先只验 302），再 git lfs pull 单个
#     对象，落盘内容不得仍是 pointer（证明对象真的下载了）
#
# 前置：runner 已注入 squid（HTTP(S)_PROXY + CA）。脚本用
#   GIT_CONFIG_GLOBAL/SYSTEM=/dev/null 剥掉宿主机 insteadOf，否则测到的是
#   /root/.gitconfig 的重写而不是 squid 的 302。
#
# 环境变量：
#   GIT302_REPO            小仓库（默认 https://github.com/octocat/Hello-World.git）
#   GIT302_REPO2           第二个仓库，验证规则不绑定单仓库
#                          （默认 https://github.com/minghuaslab/flash-attention-npu.git）
#   GIT302_SUBMODULE_REPO  带子模块的仓库（默认 jqlang/jq，子模块 kkos/oniguruma 也在 GitHub）
#   GIT302_LFS_REPO        带 LFS 对象的仓库（默认 honeynet/forensic_challenges，
#                          单个对象 ~1MB，bounded）
#   GIT302_PUSH_URL        push 目标（空=SKIP，需凭据）
#   GIT302_TIMEOUT         单条 git 命令超时秒数（默认 300）
#
# 产物：$RESULTS_DIR/git302.tsv（case/result/detail）+ $RESULTS_DIR/timings.tsv
# =============================================================================
set -uo pipefail

RESULTS_DIR="${RESULTS_DIR:-/tmp/test-squid-results}"
mkdir -p "$RESULTS_DIR"
TSV="$RESULTS_DIR/timings.tsv"
DETAIL="$RESULTS_DIR/git302.tsv"
WORK="$RESULTS_DIR/git302-work"
rm -rf "$WORK"; mkdir -p "$WORK"

printf 'phase\tseconds\tstatus\tgroup\n' > "$TSV"
printf 'case\tresult\tdetail\n' > "$DETAIL"

GIT302_REPO="${GIT302_REPO:-https://github.com/octocat/Hello-World.git}"
GIT302_REPO2="${GIT302_REPO2:-https://github.com/minghuaslab/flash-attention-npu.git}"
GIT302_SUBMODULE_REPO="${GIT302_SUBMODULE_REPO:-https://github.com/jqlang/jq.git}"
GIT302_LFS_REPO="${GIT302_LFS_REPO:-https://github.com/honeynet/forensic_challenges.git}"
GIT302_PUSH_URL="${GIT302_PUSH_URL:-}"
GIT302_TIMEOUT="${GIT302_TIMEOUT:-300}"

PASS=0; FAIL=0; SKIP=0; WARN=0

mark() {  # mark <case> <PASS|FAIL|SKIP|WARN> <detail>
    local c="$1" r="$2" d="$3"
    printf '%s\t%s\t%s\n' "$c" "$r" "$d" >> "$DETAIL"
    case "$r" in
        PASS) PASS=$((PASS+1)) ;;
        FAIL) FAIL=$((FAIL+1)) ;;
        SKIP) SKIP=$((SKIP+1)) ;;
        *)    WARN=$((WARN+1)) ;;
    esac
    echo "### [$c] $r  $d"
}

phase_row() {  # phase_row <case> <seconds> <0|1|SKIP>
    printf '%s\t%s\t%s\tgit302\n' "$1" "$2" "$3" >> "$TSV"
}

now() { date +%s; }

# ---------------------------------------------------------------------------
# 真实 git 命令：rc=0 且出现 redirecting to ...git-cdn 才算过
# ---------------------------------------------------------------------------
run_git_case() {  # run_git_case <case> <workdir> <git args...>
    local c="$1" dir="$2"; shift 2
    local log="$WORK/$c.log" rc t0 sec redirect
    rm -rf "$WORK/$c.out"
    t0=$(now)
    ( cd "$dir" && timeout "$GIT302_TIMEOUT" \
        env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0 \
        "$@" ) >"$log" 2>&1
    rc=$?
    sec=$(( $(now) - t0 ))
    if [ "$rc" -ne 0 ]; then
        phase_row "$c" "$sec" 1
        mark "$c" FAIL "rc=$rc: $(tail -3 "$log" | tr '\n' ' ' | cut -c1-240)"
        return 1
    fi
    if ! grep -qi 'redirecting to .*git-cdn' "$log"; then
        phase_row "$c" "$sec" 1
        mark "$c" FAIL "rc=0 但无 redirecting to git-cdn（302 未承载该命令）: $(tail -2 "$log" | tr '\n' ' ' | cut -c1-160)"
        return 1
    fi
    redirect=$(grep -i 'redirecting to' "$log" | head -1 | sed 's/.*redirecting to //' | cut -c1-140)
    phase_row "$c" "$sec" 0
    mark "$c" PASS "302 → $redirect"
}

# 期望失败的命令（反证 302 真实存在）
run_git_expect_fail() {  # run_git_expect_fail <case> <workdir> <git args...>
    local c="$1" dir="$2"; shift 2
    local log="$WORK/$c.log" rc t0 sec
    t0=$(now)
    ( cd "$dir" && timeout "$GIT302_TIMEOUT" \
        env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0 \
        "$@" ) >"$log" 2>&1
    rc=$?
    sec=$(( $(now) - t0 ))
    if [ "$rc" -eq 0 ]; then
        phase_row "$c" "$sec" 1
        mark "$c" FAIL "禁用 followRedirects 后仍成功（302 可能不存在/未被 Git 识别）"
        return 1
    fi
    phase_row "$c" "$sec" 0
    mark "$c" PASS "禁用 followRedirects 后按预期失败（302 真实存在）: $(tail -2 "$log" | tr '\n' ' ' | cut -c1-160)"
}

skip_case() {  # skip_case <case> <reason>
    phase_row "$1" 0 SKIP
    mark "$1" SKIP "$2"
}

# 只断言 rc=0：LFS 对象下载走 batch API + 预签名对象域，不经 info/refs 302
run_git_plain_case() {  # run_git_plain_case <case> <workdir> <command...>
    local c="$1" dir="$2"; shift 2
    local log="$WORK/$c.log" rc t0 sec
    t0=$(now)
    ( cd "$dir" && timeout "$GIT302_TIMEOUT" \
        env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0 \
        "$@" ) >"$log" 2>&1
    rc=$?
    sec=$(( $(now) - t0 ))
    if [ "$rc" -ne 0 ]; then
        phase_row "$c" "$sec" 1
        mark "$c" FAIL "rc=$rc: $(tail -3 "$log" | tr '\n' ' ' | cut -c1-240)"
        return 1
    fi
    phase_row "$c" "$sec" 0
    mark "$c" PASS "$(tail -1 "$log" | cut -c1-160)"
}

# runner 未预装 git-lfs 时按架构拉官方 release（与 tool-14 同一套自举形态）
lfs_bootstrap() {
    local ver=3.7.0 arch dir
    dir="$WORK/git-lfs-$ver"
    if [ -x "$dir/git-lfs" ]; then PATH="$dir:$PATH"; export PATH; return 0; fi
    case "$(uname -m)" in
        x86_64)        arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *)             return 1 ;;
    esac
    curl -fsSL --max-time 180 \
        "https://github.com/git-lfs/git-lfs/releases/download/v$ver/git-lfs-linux-$arch-v$ver.tar.gz" \
        | tar -xz -C "$WORK" >/dev/null 2>&1 || return 1
    [ -x "$dir/git-lfs" ] || return 1
    PATH="$dir:$PATH"; export PATH
    return 0
}

# ---------------------------------------------------------------------------
# curl 契约探头：不跟随跳转（不加 -L）
# ---------------------------------------------------------------------------
probe_location() {  # probe_location <case> <url> [method]  → 输出 "code<TAB>location"
    local c="$1" url="$2" method="${3:-GET}"
    local hdr="$WORK/$c.hdr" code loc arg=(-X "$method")
    # curl -X HEAD 会等响应体（HEAD 无体）直到超时，必须用 -I
    [ "$method" = "HEAD" ] && arg=(-I)
    code=$(curl -sS "${arg[@]}" -D "$hdr" -o /dev/null -w '%{http_code}' --max-time 60 \
        -H 'Accept: application/x-git-upload-pack-advertisement' "$url" 2>"$WORK/$c.err") || code="000"
    loc=$(grep -i '^location:' "$hdr" 2>/dev/null | head -1 | tr -d '\r' | sed 's/^[Ll]ocation: *//')
    printf '%s\t%s\n' "$code" "$loc"
}

expect_302_gitcdn() {  # expect_302_gitcdn <case> <url> <expect-path-substr> [method]
    local c="$1" url="$2" want="$3" method="${4:-GET}" out code loc
    out=$(probe_location "$c" "$url" "$method")
    code=${out%%$'\t'*}; loc=${out#*$'\t'}
    phase_row "$c" 0 "$([ "$code" = 302 ] && echo 0 || echo 1)"
    if [ "$code" != "302" ]; then
        mark "$c" FAIL "GET=$code 期望 302（$url）"
        return 1
    fi
    case "$loc" in
        *git-cdn-service*.svc.cluster.local:8000*) ;;
        *) mark "$c" FAIL "302 但 Location 未命中 git-cdn：$loc"; return 1 ;;
    esac
    if [ -n "$want" ] && [[ "$loc" != *"$want"* ]]; then
        mark "$c" FAIL "302 Location 未保留路径/查询串（缺 $want）：$loc"
        return 1
    fi
    mark "$c" PASS "302 → $loc"
}

expect_not_gitcdn() {  # expect_not_gitcdn <case> <url>
    local c="$1" url="$2" out code loc
    out=$(probe_location "$c" "$url")
    code=${out%%$'\t'*}; loc=${out#*$'\t'}
    phase_row "$c" 0 0
    case "$loc" in
        *git-cdn*) mark "$c" FAIL "非 git 路径被 302 到 git-cdn：$code $loc"; return 1 ;;
    esac
    mark "$c" PASS "未跳 git-cdn（GET=$code ${loc:+loc=$loc}）"
}

# ===========================================================================
# A. 302 契约
# ===========================================================================
echo "===== A. 302 契约（curl，不跟随跳转）====="
REPO_PATH="${GIT302_REPO#https://github.com/}"
REPO2_PATH="${GIT302_REPO2#https://github.com/}"

expect_302_gitcdn "probe-upload-pack" \
    "${GIT302_REPO%/}/info/refs?service=git-upload-pack" \
    "$REPO_PATH/info/refs?service=git-upload-pack"

# 不带 .git 后缀的仓库地址（git 常见写法）
if [[ "$GIT302_REPO" == *.git ]]; then
    NOGIT="${GIT302_REPO%.git}"
    expect_302_gitcdn "probe-upload-pack-nogit" \
        "${NOGIT%/}/info/refs?service=git-upload-pack" \
        "${NOGIT#https://github.com/}/info/refs?service=git-upload-pack"
fi

expect_302_gitcdn "probe-upload-pack-repo2" \
    "${GIT302_REPO2%/}/info/refs?service=git-upload-pack" \
    "$REPO2_PATH/info/refs?service=git-upload-pack"

# HEAD 方法：部分 helper 只在 GET 分支生效，HEAD 未覆盖也算留档
out=$(probe_location "probe-head" "${GIT302_REPO%/}/info/refs?service=git-upload-pack" HEAD)
code=${out%%$'\t'*}; loc=${out#*$'\t'}
phase_row "probe-head" 0 0
if [ "$code" = "302" ]; then
    mark "probe-head" PASS "HEAD 同样 302 → $loc"
else
    mark "probe-head" WARN "HEAD=$code（GET 才是 git 实际使用的分支，仅留档）"
fi

# 无 service query：git 客户端不会这样请求，仅留档形态
out=$(probe_location "probe-noquery" "${GIT302_REPO%/}/info/refs")
code=${out%%$'\t'*}; loc=${out#*$'\t'}
phase_row "probe-noquery" 0 0
case "$loc" in
    *git-cdn*) mark "probe-noquery" PASS "无 query 也 302 → $loc" ;;
    *)         mark "probe-noquery" WARN "无 query GET=$code（规则仅匹配带 service 的形态，git 不触发）" ;;
esac

# receive-pack（push 形态）：200=push 不经缓存（合理）；302 git-cdn=需确认其支持 receive-pack
out=$(probe_location "probe-receive-pack" "${GIT302_REPO%/}/info/refs?service=git-receive-pack")
code=${out%%$'\t'*}; loc=${out#*$'\t'}
phase_row "probe-receive-pack" 0 0
if [ "$code" = "302" ]; then
    case "$loc" in
        *git-cdn*) mark "probe-receive-pack" WARN "receive-pack 也被 302 到 git-cdn（需确认 git-cdn 是否支持 push）：$loc" ;;
        *)         mark "probe-receive-pack" WARN "receive-pack 302 到非 git-cdn：$loc" ;;
    esac
else
    mark "probe-receive-pack" PASS "receive-pack 未重定向（GET=$code，push 不受缓存策略影响）"
fi

# 负样本 1：archive 静态包可来自 codeload，不能跳到 git-cdn
expect_not_gitcdn "probe-archive-tar" "https://github.com/${REPO_PATH%.git}/archive/refs/heads/master.tar.gz"
# 负样本 2：仓库 HTML 页
expect_not_gitcdn "probe-html-page" "https://github.com/${REPO_PATH%.git}"

# ===========================================================================
# B. 真实 git 命令
# ===========================================================================
echo "===== B. 真实 git 命令（insteadOf 已剥离）====="

# ls-remote 系列
run_git_case "ls-remote" "$WORK" git ls-remote "$GIT302_REPO"
run_git_case "ls-remote-heads-tags" "$WORK" git ls-remote --heads --tags "$GIT302_REPO"
run_git_case "ls-remote-symref" "$WORK" git ls-remote --symref "$GIT302_REPO" HEAD
run_git_case "ls-remote-ref" "$WORK" git ls-remote "$GIT302_REPO" refs/heads/master
run_git_case "ls-remote-protocol-v0" "$WORK" git -c protocol.version=0 ls-remote "$GIT302_REPO" HEAD
run_git_case "ls-remote-protocol-v2" "$WORK" git -c protocol.version=2 ls-remote "$GIT302_REPO" HEAD

# clone 系列（Hello-World 很小，full clone 也是秒级）
CLONE_FULL="$WORK/clone-full"; CLONE_SHALLOW="$WORK/clone-depth1"
rm -rf "$CLONE_FULL" "$CLONE_SHALLOW"
run_git_case "clone-full" "$WORK" git clone "$GIT302_REPO" "$CLONE_FULL"
run_git_case "clone-depth1" "$WORK" git clone --depth 1 "$GIT302_REPO" "$CLONE_SHALLOW"
run_git_case "clone-filter" "$WORK" git clone --depth 1 --filter=blob:none --no-checkout \
    "$GIT302_REPO" "$WORK/clone-filter"
run_git_case "clone-single-branch" "$WORK" git clone --single-branch --branch master --depth 1 \
    "$GIT302_REPO" "$WORK/clone-single"
run_git_case "clone-bare" "$WORK" git clone --bare "$GIT302_REPO" "$WORK/clone-bare.git"

# 反证：禁用跟随跳转必须失败
run_git_expect_fail "clone-nofollow-must-fail" "$WORK" git -c http.followRedirects=false \
    clone --depth 1 "$GIT302_REPO" "$WORK/clone-nofollow"

# fetch 系列（在 full clone 上：tags / prune / pull；在 shallow 上：deepen / unshallow）
if [ -d "$CLONE_FULL/.git" ]; then
    run_git_case "fetch-tags" "$CLONE_FULL" git fetch --tags origin
    run_git_case "fetch-prune" "$CLONE_FULL" git fetch --prune origin
    run_git_case "pull-ff-only" "$CLONE_FULL" git pull --ff-only origin master
    run_git_case "remote-show" "$CLONE_FULL" git remote show origin
    run_git_case "remote-update" "$CLONE_FULL" git remote update origin
else
    skip_case "fetch-tags" "full clone 未成功"
    skip_case "fetch-prune" "full clone 未成功"
    skip_case "pull-ff-only" "full clone 未成功"
    skip_case "remote-show" "full clone 未成功"
    skip_case "remote-update" "full clone 未成功"
fi

if [ -d "$CLONE_SHALLOW/.git" ]; then
    run_git_case "fetch-deepen" "$CLONE_SHALLOW" git fetch --deepen=1 origin
    run_git_case "fetch-unshallow" "$CLONE_SHALLOW" git fetch --unshallow origin
else
    skip_case "fetch-deepen" "shallow clone 未成功"
    skip_case "fetch-unshallow" "shallow clone 未成功"
fi

# actions/checkout 形态：init + remote add + 按 SHA 浅取
SHA_DIR="$WORK/checkout-by-sha"; rm -rf "$SHA_DIR"
HEAD_SHA=$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0 \
    timeout "$GIT302_TIMEOUT" git ls-remote "$GIT302_REPO" HEAD 2>/dev/null | awk 'NR==1{print $1}')
if [ -n "$HEAD_SHA" ] && git init -q "$SHA_DIR"; then
    git -C "$SHA_DIR" remote add origin "$GIT302_REPO"
    run_git_case "fetch-by-sha" "$SHA_DIR" git fetch --depth 1 origin "$HEAD_SHA"
else
    skip_case "fetch-by-sha" "取不到 HEAD SHA 或 git init 失败"
fi

# ---------------------------------------------------------------------------
# submodule：顶层 clone 走 302，子模块 URL 也是 github.com → 同一条 302 规则
# 断言：clone rc=0 + 出现 redirecting + `git submodule status` 非空（真拉下来了）
# ---------------------------------------------------------------------------
if [ -n "$GIT302_SUBMODULE_REPO" ]; then
    rm -rf "$WORK/clone-submodule"
    # 两步形态：先用 blob:none + no-checkout 把超级仓库压到最小（jq ~8MB 仓库只取
    # commit/tree，实传百 KB），read-tree 把 gitlink 放进 index，再浅拉子模块。
    # 一步 `clone --recurse-submodules` 会连同超级仓库全部 blob 一起下，冷缓存下
    # 300s 超时（gy-006 实测 rc=124）。
    if run_git_case "clone-recurse-submodules" "$WORK" bash -c '
        git clone --depth 1 --filter=blob:none --no-checkout "$1" "$2" &&
        git -C "$2" read-tree HEAD &&
        git -C "$2" submodule update --init --depth 1
    ' _ "$GIT302_SUBMODULE_REPO" "$WORK/clone-submodule"; then
        subs=$(git -C "$WORK/clone-submodule" submodule status 2>/dev/null)
        n=$(printf '%s\n' "$subs" | grep -c . || true)
        if [ "$n" -gt 0 ]; then
            phase_row "submodule-populated" 0 0
            mark "submodule-populated" PASS "$n 个子模块已拉取: $(printf '%s\n' "$subs" | awk '{print $2}' | tr '\n' ' ')"
        else
            phase_row "submodule-populated" 0 1
            mark "submodule-populated" FAIL "clone rc=0 但 submodule status 为空（子模块未拉取）"
        fi
    fi
else
    skip_case "clone-recurse-submodules" "未设置 GIT302_SUBMODULE_REPO"
fi

# ---------------------------------------------------------------------------
# LFS：clone 先 SKIP_SMUDGE（只验 302 覆盖到 repo 发现），再单独 pull 一个对象，
# 断言落盘内容不再是 pointer（batch API + 对象下载真的成功）
# ---------------------------------------------------------------------------
if [ -n "$GIT302_LFS_REPO" ]; then
    if command -v git-lfs >/dev/null 2>&1 || lfs_bootstrap; then
        rm -rf "$WORK/clone-lfs"
        if run_git_case "clone-lfs-repo" "$WORK" env GIT_LFS_SKIP_SMUDGE=1 \
            git clone --depth 1 "$GIT302_LFS_REPO" "$WORK/clone-lfs"; then
            git -C "$WORK/clone-lfs" lfs install --local >/dev/null 2>&1 || true
            obj=$(git -C "$WORK/clone-lfs" lfs ls-files -n 2>/dev/null | head -1)
            if [ -z "$obj" ]; then
                skip_case "lfs-pull-one" "HEAD 无 LFS 跟踪文件（git lfs ls-files 为空）"
            else
                phase_row "lfs-tracked" 0 0
                mark "lfs-tracked" PASS "LFS 跟踪文件 $obj"
                if run_git_plain_case "lfs-pull-one" "$WORK/clone-lfs" \
                    git lfs pull --include="$obj"; then
                    if head -c 64 "$WORK/clone-lfs/$obj" 2>/dev/null | grep -q 'version https://git-lfs'; then
                        phase_row "lfs-object-real" 0 1
                        mark "lfs-object-real" FAIL "$obj 仍是 pointer（对象未真正下载）"
                    else
                        phase_row "lfs-object-real" 0 0
                        mark "lfs-object-real" PASS "$obj 已落盘 $(wc -c <"$WORK/clone-lfs/$obj" 2>/dev/null) 字节（非 pointer）"
                    fi
                fi
            fi
        fi
    else
        skip_case "clone-lfs-repo" "无 git-lfs 且官方 release 自举失败（$GIT302_LFS_REPO 无法校验对象）"
    fi
else
    skip_case "clone-lfs-repo" "未设置 GIT302_LFS_REPO"
fi

if [ -n "$GIT302_PUSH_URL" ]; then
    run_git_case "push-dry-run" "$CLONE_FULL" git push --dry-run "$GIT302_PUSH_URL" HEAD:refs/heads/git302-probe
else
    skip_case "push-dry-run" "未设置 GIT302_PUSH_URL（push 需写权限，默认不测）"
fi

skip_case "archive-remote" "GitHub 不支持 git archive --remote（HTTP 无 upload-archive）"

# ===========================================================================
# 汇总
# ===========================================================================
echo ""
echo "===== git302 汇总：PASS=$PASS FAIL=$FAIL WARN=$WARN SKIP=$SKIP ====="
if [ "$FAIL" -gt 0 ]; then
    echo "❌ 有 $FAIL 个用例未通过（明细见 $DETAIL）"
    awk -F'\t' '$2=="FAIL"{printf "    %s\t%s\n", $1, $3}' "$DETAIL"
    exit 1
fi
echo "✅ 全部必测用例通过（WARN/SKIP 仅留档）"
