#!/usr/bin/env bash
# =============================================================================
# repro-gitcdn-lfs.sh —— git-cdn 跨域 LFS 缓存（batch 改写 + 对象缓存 + 验签）
#
# 背景（opensourceways/git-cache-http-server issue #48 / PR #49）：
#   git-cdn 原先只缓存与上游同源的 LFS（GitLab 形态：href 直接替换 base）。
#   GitHub / GitCode 的对象在外部 CDN，batch 返回的 href 不带 git-cdn 地址，
#   客户端绕过缓存直连 CDN。PR #49 起：
#     · batch 里 download href 改写为
#       <本实例>/<repo>.git/info/lfs/objects/<oid>?_lfs=<AES-GCM payload>.<HMAC>&exp=<epoch>
#     · 对象 GET 先验签（HMAC 绑定 repo / oid / exp），篡改/过期/换 oid 一律 403；
#     · 验签通过后按 repo+oid 落盘并回源，二次访问直接读缓存；
#     · batch 后异步预热（_prefetch），首访可能已是 HIT（竞态 → 时延只留档）；
#     · UA 不含 "git" 的浏览器请求 308 重定向回上游，避免浏览器拿到签名地址。
#
# 用例 G6（两个实例各跑一遍）：
#   GitHub  实例 http://git-cdn-service.git-cdn.svc.cluster.local:8000
#            upstream=gh-proxy→github.com，repo=Unity-Technologies/BoatAttack
#   GitCode 实例 http://git-cdn-service.git-cdn-gitcode.svc.cluster.local:8000
#            upstream=gitcode.com，repo=gh_mirrors/bo/BoatAttack
#   每实例：
#     ① batch（UA=git-lfs）200，href 指回本实例且带 _lfs/exp → 跨域改写生效
#     ② href GET 两次：均 200 且 sha256==oid → 缓存内容与 pointer 一致
#     ③ 无 token / 篡改 token / oid 不符 → 403（可选：过期 token → 403）
#     ④ 浏览器 UA batch → 308 且 Location 非空
#
# 判定：
#   · 任一断言不符 → FAIL；实例不可达 → SKIP；
#   · batch 200 但 href 未改写（旧镜像未启用跨域 LFS）→ LFS_STRICT=1 判 FAIL，
#     否则记 SKIP（用于尚未部署该镜像的集群）；
#   · 时延只留档：batch 即触发预热，"首访冷/二访热"可能被预热抹平，不能作为
#     命中硬判据（命中证据看 Pod 日志 lfs_hit=True / lfs_served）。
#
# 注意：对象 GET 500 且日志为 OSError Quota exceeded: '/workdir/lfs' 属
#   SFS Turbo 配额/容量问题（2026-11-27 gy-006 实测），不是本用例逻辑失败，
#   需先清理/扩容共享盘再重跑。
#
# 用法：
#   bash test-squid/repro-gitcdn-lfs.sh
#
# 可覆盖：
#   LFS_GITHUB_BASE / LFS_GITCODE_BASE   两个实例基址
#   LFS_GITHUB_REPO / LFS_GITCODE_REPO   目标仓库（须含 LFS 对象；owner/repo，不带 .git）
#   LFS_OID / LFS_SIZE                   目标对象（默认 BoatAttack 的 20KB 对象）
#   LFS_STRICT                           1=未改写判红（默认，gy-006）；0=未改写记 SKIP
#   LFS_URL_SECRET                       可选；提供时补「过期 token → 403」用例
#   LFS_TIMEOUT                          单请求超时秒数（默认 300）
#   RESULTS                              结果目录（默认 $RESULTS_DIR/gitcdn-lfs）
#
# 输出：lfs.tsv（id/phase/status/seconds/note）+ <实例>-batch.json/.hdr/.objN.bin
# 退出码：0=PASS；1=FAIL；2=SKIP（两个实例都不可达/都未启用特性）
# =============================================================================
set -uo pipefail

GH_BASE="${LFS_GITHUB_BASE:-http://git-cdn-service.git-cdn.svc.cluster.local:8000}"
GC_BASE="${LFS_GITCODE_BASE:-http://git-cdn-service.git-cdn-gitcode.svc.cluster.local:8000}"
GH_REPO="${LFS_GITHUB_REPO:-Unity-Technologies/BoatAttack}"
GC_REPO="${LFS_GITCODE_REPO:-gh_mirrors/bo/BoatAttack}"
OID="${LFS_OID:-df2fcd2b9b07ae2eadd8c916a19d4296c61eb7089501aa271d0f6997191d6d13}"
SIZE="${LFS_SIZE:-20249}"
STRICT="${LFS_STRICT:-1}"
SECRET="${LFS_URL_SECRET:-}"
TIMEOUT="${LFS_TIMEOUT:-300}"
results="${RESULTS:-${RESULTS_DIR:-/tmp/test-squid-results}/gitcdn-lfs}"

mkdir -p "$results"
TSV="$results/lfs.tsv"
printf 'id\tphase\tstatus\tseconds\tnote\n' >"$TSV"

UA="git-lfs/3.5.1 (GitHub; linux amd64; go 1.21.3)"
BROWSER_UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/131.0 Safari/537.36"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# 统一 timings 五列：id, phase, status, seconds, note（G6 = 跨域 LFS 用例）
step() {  # <phase> <status(PASS|FAIL|SKIP)> <seconds> [note]
    local ph=$1 st=$2 sec=$3 note=${4:-}
    printf 'G6\tG6-%s\t%s\t%s\t%s\n' "$ph" "$st" "$sec" "$note" >>"$TSV"
}

# http <body-out> <hdr-out|-> <method> <url> [curl args...] → "http_code time_total"
http() {
    local body=$1 hdr=$2 method=$3 url=$4
    shift 4
    local args=(-sS -m "$TIMEOUT" -X "$method" -o "$body" -w '%{http_code} %{time_total}')
    [ "$hdr" != "-" ] && args+=(-D "$hdr")
    curl "${args[@]}" "$@" "$url" 2>/dev/null || echo "000 0"
}

# 括号内执行 curl 并读 code/sec：read -r code sec <<<"$(http ...)"
command -v python3 >/dev/null 2>&1 || { log "⚠️ 无 python3，无法解析 batch JSON"; exit 2; }
command -v curl >/dev/null 2>&1 || { log "⚠️ 无 curl"; exit 2; }

# 解析 batch JSON：输出 "<href> <error>"（无值用 "-"）
parse_batch() {
    python3 - "$1" <<'PY'
import json, sys
try:
    js = json.load(open(sys.argv[1]))
except Exception:
    print("- -"); raise SystemExit
objs = js.get("objects") or []
if not objs:
    print("- -"); raise SystemExit
o = objs[0]
if "error" in o:
    e = o.get("error") or {}
    print("- " + str(e.get("message") or e.get("code") or "error"))
elif o.get("actions", {}).get("download"):
    print(o["actions"]["download"]["href"] + " -")
else:
    print("- -")
PY
}

strip_query() {
    python3 - "$1" <<'PY'
import sys, urllib.parse as u
p = u.urlsplit(sys.argv[1])
print(u.urlunsplit((p.scheme, p.netloc, p.path, "", "")))
PY
}

tamper_query() {
    python3 - "$1" <<'PY'
import sys, urllib.parse as u
p = u.urlsplit(sys.argv[1])
q = u.parse_qs(p.query)
tok, mac = q["_lfs"][0].split(".", 1)
tok = ("A" if tok[0] != "A" else "B") + tok[1:]
q["_lfs"] = [tok + "." + mac]
print(u.urlunsplit((p.scheme, p.netloc, p.path, u.urlencode(q, doseq=True), "")))
PY
}

swap_oid() {
    python3 - "$1" <<'PY'
import sys, urllib.parse as u
p = u.urlsplit(sys.argv[1])
path = p.path
if "/info/lfs/objects/" in p.path:
    head, _, _ = p.path.partition("/info/lfs/objects/")
    path = head + "/info/lfs/objects/" + "0" * 64
print(u.urlunsplit((p.scheme, p.netloc, path, p.query, "")))
PY
}

# 过期 token：用 LFS_URL_SECRET 重算 HMAC（exp 绑定在签名里，必须同密钥）
expired_url() {  # expired_url <href> <repo.git> <oid>
    python3 - "$1" "$2" "$3" "$SECRET" <<'PY'
import base64, hashlib, hmac, sys, time, urllib.parse as u
href, repo, oid, secret = sys.argv[1:5]
p = u.urlsplit(href)
q = u.parse_qs(p.query)
tok = q["_lfs"][0].split(".", 1)[0]
exp = int(time.time()) - 10
key = hashlib.sha256((secret + ":hmac").encode()).digest()
msg = f"{repo}\n{oid}\n{exp}\n{tok}".encode()
mac = base64.urlsafe_b64encode(hmac.new(key, msg, hashlib.sha256).digest()).decode().rstrip("=")
print(u.urlunsplit((p.scheme, p.netloc, p.path, f"_lfs={tok}.{mac}&exp={exp}", "")))
PY
}

run_instance() {  # <name> <base> <repo>
    local name=$1 base=$2 repo=$3
    base="${base%/}"
    local gitrepo="$repo.git"
    local bad=0

    # ① 可达性
    local code sec
    read -r code sec <<<"$(http "$results/$name-root.body" - GET "$base/")"
    if [ "$code" != "200" ]; then
        step "$name-0-reach" SKIP "$sec" "base=$base GET=$code（集群无该实例或不可达）"
        return 2
    fi
    step "$name-0-reach" PASS "$sec" "base=$base"

    # ② batch（git-lfs UA）
    local batch_url="$base/$gitrepo/info/lfs/objects/batch"
    local payload
    payload=$(printf '{"operation":"download","transfers":["basic"],"objects":[{"oid":"%s","size":%s}]}' "$OID" "$SIZE")
    read -r code sec <<<"$(http "$results/$name-batch.json" "$results/$name-batch.hdr" POST "$batch_url" \
        -H "User-Agent: $UA" \
        -H 'Accept: application/vnd.git-lfs+json' \
        -H 'Content-Type: application/vnd.git-lfs+json' \
        -d "$payload")"
    if [ "$code" != "200" ]; then
        step "$name-1-batch" FAIL "$sec" "batch http=$code url=$batch_url"
        return 1
    fi

    local href err
    read -r href err <<<"$(parse_batch "$results/$name-batch.json")"
    if [ "$err" != "-" ] && [ "$err" != "" ]; then
        step "$name-1-batch" SKIP "$sec" "上游无该对象/需鉴权: $err"
        return 2
    fi
    if [ "$href" = "-" ] || [ -z "$href" ]; then
        step "$name-1-batch" FAIL "$sec" "batch 无 download action（响应见 $name-batch.json）"
        return 1
    fi

    # ③ 改写断言：href 必须指回本实例，且带 _lfs/exp
    case "$href" in
        "$base/$gitrepo/info/lfs/objects/$OID"*"_lfs="*"exp="*)
            step "$name-2-rewrite" PASS "$sec" "href→本实例（带 _lfs/exp）" ;;
        *)
            if [ "$STRICT" = "1" ]; then
                step "$name-2-rewrite" FAIL "$sec" "batch 200 但 href 未改写（镜像未启用跨域 LFS？）href=${href:0:80}"
                return 1
            fi
            step "$name-2-rewrite" SKIP "$sec" "href 未改写，非 gy-006 镜像；跳过后续断言"
            return 2 ;;
    esac

    # ④ 对象 GET 两次：完整性与时延（时延只留档）
    local f1="$results/$name-obj1.bin" f2="$results/$name-obj2.bin"
    local sec1 sec2 code1 code2 sha1 sha2
    read -r code1 sec1 <<<"$(http "$f1" - GET "$href" -H "User-Agent: $UA")"
    read -r code2 sec2 <<<"$(http "$f2" - GET "$href" -H "User-Agent: $UA")"
    sha1=$(sha256sum "$f1" 2>/dev/null | awk '{print $1}')
    sha2=$(sha256sum "$f2" 2>/dev/null | awk '{print $1}')
    if [ "$code1" != "200" ] || [ "$code2" != "200" ]; then
        local hint=""
        [ "$code1" = "500" ] && hint="（500 常见于 /workdir 配额满，见文件头注记）"
        step "$name-3-object" FAIL "$sec2" "GET1=$code1 GET2=$code2$hint"
        bad=1
    elif [ "$sha1" != "$OID" ] || [ "$sha2" != "$OID" ]; then
        step "$name-3-object" FAIL "$sec2" "sha256 不符 GET1=${sha1:0:12} GET2=${sha2:0:12} expect=${OID:0:12}"
        bad=1
    else
        step "$name-3-object" PASS "$sec2" "两发均 200 且 sha256==oid；t1=${sec1}s t2=${sec2}s（预热竞态，时延仅留档）"
    fi

    # ⑤ 负数：无 token / 篡改 token / oid 不符（均应 403；可选过期）
    local kind url2 got gsec
    for kind in notoken tampered oidmismatch expired; do
        case "$kind" in
            notoken)     url2=$(strip_query "$href") ;;
            tampered)    url2=$(tamper_query "$href") ;;
            oidmismatch) url2=$(swap_oid "$href") ;;
            expired)
                if [ -z "$SECRET" ]; then
                    step "$name-4-$kind" SKIP 0 "未提供 LFS_URL_SECRET（可手动跑；默认 workflow 不注入）"
                    continue
                fi
                url2=$(expired_url "$href" "$gitrepo" "$OID") ;;
        esac
        read -r got gsec <<<"$(http "$results/$name-neg-$kind.body" - GET "$url2" -H "User-Agent: $UA")"
        if [ "$got" = "403" ]; then
            step "$name-4-$kind" PASS "$gsec" "403"
        else
            step "$name-4-$kind" FAIL "$gsec" "http=$got（预期 403）"
            bad=1
        fi
    done

    # ⑥ 浏览器 UA batch → 308 回上游（不跟随跳转）
    read -r code sec <<<"$(http "$results/$name-browser.body" "$results/$name-browser.hdr" POST "$batch_url" \
        -H "User-Agent: $BROWSER_UA" \
        -H 'Accept: application/vnd.git-lfs+json' \
        -H 'Content-Type: application/vnd.git-lfs+json' \
        -d "$payload")"
    local loc
    loc=$(awk 'tolower($1)=="location:"{sub(/^[^:]*:[ \t]*/,""); sub(/\r$/,""); print; exit}' \
        "$results/$name-browser.hdr" 2>/dev/null)
    if [ "$code" = "308" ] && [ -n "$loc" ]; then
        step "$name-5-browser" PASS "$sec" "308 → ${loc:0:80}"
    elif [ "$code" = "308" ]; then
        step "$name-5-browser" FAIL "$sec" "308 但无 Location"
        bad=1
    else
        step "$name-5-browser" FAIL "$sec" "http=$code（预期 308）"
        bad=1
    fi

    [ "$bad" = "0" ] && return 0
    return 1
}

log "== G6 跨域 LFS：GitHub 实例（$GH_REPO @ $GH_BASE）=="
run_instance github "$GH_BASE" "$GH_REPO"; rc_gh=$?
log "== G6 跨域 LFS：GitCode 实例（$GC_REPO @ $GC_BASE）=="
run_instance gitcode "$GC_BASE" "$GC_REPO"; rc_gc=$?

log "== 结果（$TSV）=="
cat "$TSV"

fails=0; passes=0; skips=0
for rc in "$rc_gh" "$rc_gc"; do
    case "$rc" in
        0) passes=$((passes + 1)) ;;
        1) fails=$((fails + 1)) ;;
        *) skips=$((skips + 1)) ;;
    esac
done

if [ "$fails" -gt 0 ]; then
    log "❌ G6 FAIL：${fails} 个实例断言失败（pass=$passes skip=$skips）"
    exit 1
fi
if [ "$passes" -gt 0 ]; then
    log "✅ G6 PASS：${passes} 个实例通过（skip=$skips）"
    exit 0
fi
log "⚠️ G6 SKIP：两个实例都不可达或未启用跨域 LFS（strict=$STRICT）"
exit 2
