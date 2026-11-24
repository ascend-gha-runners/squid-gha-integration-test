#!/usr/bin/env bash
# =============================================================================
# purge-gitcdn-cache.sh —— 清掉 git-cdn 上某个仓库的缓存，供冷启动用例使用
#
# 背景：git-cdn 有两层缓存，都在容器内 /workdir：
#   - mirror：/workdir/git/<org>/<repo>.git，按仓库分目录，可以单独删
#   - pack_cache：/workdir/pack_cache，按请求哈希分目录（hash[:2]），
#     没有仓库维度的索引，无法只删某个仓库的 pack
#
# 因此：
#   - 删 mirror 是精确操作
#   - 删 pack_cache 只能整体清空，会影响所有仓库下一次回源，必须显式开启
#
# 本脚本在**有 kubectl 权限的机器**上运行（CI runner 没有集群权限），
# 清完后再触发 test-gitcode-clone / test-gitcdn 的用例。
#
# 用法：
#   KUBECONFIG=~/.kube/gy-006.yaml bash test-squid/purge-gitcdn-cache.sh
#   PURGE_PACK_CACHE=1 KUBECONFIG=~/.kube/gy-006.yaml bash test-squid/purge-gitcdn-cache.sh
#
# 可覆盖：
#   GIT_CDN_NAMESPACE  命名空间（默认 git-cdn-gitcode）
#   GIT_CDN_DEPLOY     Deployment 名（默认 git-cdn）
#   REPO_PATH          仓库路径（默认 ascend/pytorch）
#   WORKDIR            容器内缓存根（默认 /workdir）
#   PURGE_PACK_CACHE   1=整体清空 pack_cache（默认 0）
#   DRY_RUN            1=只打印将要删除的路径
#
# 退出码：0=成功；1=失败；2=参数/环境不满足
# =============================================================================
set -uo pipefail

NS="${GIT_CDN_NAMESPACE:-git-cdn-gitcode}"
DEPLOY="${GIT_CDN_DEPLOY:-git-cdn}"
REPO_PATH="${REPO_PATH:-ascend/pytorch}"
WORKDIR="${WORKDIR:-/workdir}"
PURGE_PACK_CACHE="${PURGE_PACK_CACHE:-0}"
DRY_RUN="${DRY_RUN:-0}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
kc() { kubectl -n "$NS" exec "deploy/$DEPLOY" -- sh -c "$1"; }

command -v kubectl >/dev/null 2>&1 || { log "❌ 未找到 kubectl"; exit 2; }
[ -n "${KUBECONFIG:-}" ] && [ ! -r "$KUBECONFIG" ] && { log "❌ KUBECONFIG 不可读: $KUBECONFIG"; exit 2; }

mirror="$WORKDIR/git/$REPO_PATH.git"

log "命名空间=$NS Deployment=$DEPLOY 仓库=$REPO_PATH"
kc "ls -d '$mirror' 2>/dev/null && du -sh '$mirror'" || log "mirror 不存在（可能已经是冷的）"
kc "du -sh '$WORKDIR/pack_cache' 2>/dev/null" || true

if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1，未做任何删除"
    exit 0
fi

kc "rm -rf '$mirror' '$mirror.lock'" || { log "❌ 删除 mirror 失败"; exit 1; }
log "已删除 mirror: $mirror"

if [ "$PURGE_PACK_CACHE" = "1" ]; then
    kc "rm -rf '$WORKDIR/pack_cache'/*" || { log "❌ 清空 pack_cache 失败"; exit 1; }
    log "已清空 pack_cache（影响所有仓库下次回源）"
else
    log "未清 pack_cache（如需真正冷启动，加 PURGE_PACK_CACHE=1）"
fi

echo "--- 清理后状态 ---"
kc "ls -d '$mirror' 2>&1; echo -n 'pack_cache: '; du -sh '$WORKDIR/pack_cache' 2>/dev/null | cut -f1"

log "✅ 完成；下一步触发 test-gitcode-clone（iterations>=2）和 test-gitcdn（gitcdn-refspec）"
