#!/usr/bin/env bash
# Vermouth 云端 Linux 开发环境一键配置（供 Claude Code 云端会话 / 任意 Ubuntu 24.04 x86_64 容器使用）
#
# 作用：安装与开发机同版本的 Swift 工具链，使 `swift build` / `swift test` 能在 Linux 上编译并测试
#       VermouthCore + VermouthCLI（VermouthApp 依赖 SwiftUI/AppKit，只能在 macOS / GitHub Actions 上编译）。
#
# 用法：
#   sudo ./Scripts/setup-cloud-linux.sh            # 安装到 /opt/swift（已安装则跳过）
#   export PATH=/opt/swift/usr/bin:$PATH
#
# 下载源（按顺序尝试）：
#   1. download.swift.org 官方 tarball（需网络策略放行该域名）
#   2. mirror.gcr.io 上的官方 Docker 镜像 swift:<ver>-noble（直接拉取镜像层，无需 docker 守护进程）
set -euo pipefail

SWIFT_VERSION="${SWIFT_VERSION:-6.3.3}"
SWIFT_PREFIX="${SWIFT_PREFIX:-/opt/swift}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

log() { printf '==> %s\n' "$*"; }

if [[ -x "$SWIFT_PREFIX/usr/bin/swift" ]] && "$SWIFT_PREFIX/usr/bin/swift" --version 2>/dev/null | grep -q "Swift version $SWIFT_VERSION"; then
    log "Swift $SWIFT_VERSION 已安装于 $SWIFT_PREFIX，跳过"
    exit 0
fi

log "安装 Swift 运行与编译依赖（apt）"
export DEBIAN_FRONTEND=noninteractive
apt-get -q update >/dev/null
apt-get -q install -y --no-install-recommends \
    binutils libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev libpython3-dev \
    libsqlite3-0 libstdc++-13-dev libxml2-dev libncurses-dev libz3-dev pkg-config \
    tzdata zlib1g-dev ca-certificates curl python3 >/dev/null

mkdir -p "$SWIFT_PREFIX"

OFFICIAL_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu2404/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-ubuntu24.04.tar.gz"
if curl -fsSL --retry 2 -o "$WORK_DIR/swift.tar.gz" "$OFFICIAL_URL" 2>/dev/null; then
    log "从 download.swift.org 下载成功，解压中"
    tar xzf "$WORK_DIR/swift.tar.gz" -C "$SWIFT_PREFIX" --strip-components=1
else
    log "download.swift.org 不可达，改从 mirror.gcr.io 拉取官方镜像 swift:${SWIFT_VERSION}-noble"
    python3 - "$SWIFT_VERSION" "$WORK_DIR" <<'PY'
import json, sys, urllib.request
ver, out = sys.argv[1], sys.argv[2]
base = "https://mirror.gcr.io/v2/library/swift"
def get(url, accept=None):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"Accept": accept} if accept else {}))
idx = json.load(get(f"{base}/manifests/{ver}-noble",
    "application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json"))
digest = next(m["digest"] for m in idx["manifests"] if m.get("platform", {}).get("architecture") == "amd64")
man = json.load(get(f"{base}/manifests/{digest}",
    "application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"))
# 工具链所在的层是体积最大的那一层（ubuntu 基础层与 apt 依赖层都小得多）
layer = max(man["layers"], key=lambda l: l["size"])
with get(f"{base}/blobs/{layer['digest']}") as r, open(f"{out}/toolchain-layer.tar.gz", "wb") as f:
    while chunk := r.read(1 << 20):
        f.write(chunk)
PY
    tar xzf "$WORK_DIR/toolchain-layer.tar.gz" -C "$SWIFT_PREFIX"
fi

"$SWIFT_PREFIX/usr/bin/swift" --version
log "完成。请执行：export PATH=$SWIFT_PREFIX/usr/bin:\$PATH"
