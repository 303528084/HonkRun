#!/bin/sh
# honk .run installer -- this script runs ON the OpenWrt router.
# It is embedded into the self-extracting archive by scripts/build-run.sh.
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SELF_DIR/build-info.sh" ]; then
  . "$SELF_DIR/build-info.sh"
fi

HONK_BUILD_VERSION="${HONK_BUILD_VERSION:-unknown}"
HONK_BUILD_ARCH="${HONK_BUILD_ARCH:-unknown}"
HONK_BUILD_FEED="${HONK_BUILD_FEED:-https://openwrt.daeuniverse.org/25.12/packages}"
HONK_BUILD_DATE="${HONK_BUILD_DATE:-unknown}"

# Expected sha256 of the daeuniverse feed public key. A mismatch only warns: upstream may
# have rotated the key. Set HONK_FEED_KEY_SHA256 to silence/update the expectation.
FEED_KEY_URL="${HONK_FEED_KEY_URL:-https://openwrt.daeuniverse.org/public-key.pem}"
FEED_KEY_SHA256="${HONK_FEED_KEY_SHA256:-5aae30568b7e08f86ea3e72a19fa281d835ba4eff8ab38849abcd2b0884c6cd5}"

MODE="online"
ENABLE=0
WITH_LUCI=1
ALLOW_ARCH_MISMATCH=0

log()  { printf '[honk] %s\n' "$*"; }
warn() { printf '[honk][WARN] %s\n' "$*" >&2; }
die()  { printf '[honk][ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: sh 25_honk_<版本>_<架构>.run [选项]

  (无参数)      在线安装：配置 daeuniverse 官方 apk 源并安装（推荐）
  --offline     离线安装：只安装本包内置的 .apk，不联网
  --online      显式指定在线安装
  --no-luci     不安装 LuCI 界面与语言包
  --enable      安装完成后立即 enable + start 服务（默认不启动）
  --force       架构不匹配时仍然继续安装（危险，默认中止）
  --help        显示本帮助

  只解压不安装： sh xxx.run --target DIR --noexec
  给安装脚本传参：sh xxx.run -- --offline --no-luci
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --)          shift ;;
    --offline)   MODE="offline"; shift ;;
    --online)    MODE="online"; shift ;;
    --no-luci)   WITH_LUCI=0; shift ;;
    --enable)    ENABLE=1; shift ;;
    --force)     ALLOW_ARCH_MISMATCH=1; shift ;;
    --help|-h)   usage; exit 0 ;;
    *)           die "未知参数: $1 （用 --help 查看用法）" ;;
  esac
done

case "${HONK_OFFLINE:-}" in
  1|yes|true) MODE="offline" ;;
esac
case "${HONK_ALLOW_ARCH_MISMATCH:-}" in
  1|yes|true) ALLOW_ARCH_MISMATCH=1 ;;
esac

log "honk ${HONK_BUILD_VERSION} / ${HONK_BUILD_ARCH} / built ${HONK_BUILD_DATE}"
log "安装模式: ${MODE}"

[ "$(id -u)" -eq 0 ] || die "需要 root 权限，请以 root 运行。"
command -v apk >/dev/null 2>&1 || die "未找到 apk 包管理器；本包只支持 OpenWrt 25.12+（apk 体系），不支持 opkg。"
[ -f /etc/openwrt_release ] || die "未找到 /etc/openwrt_release，这看起来不是 OpenWrt 系统。"

. /etc/openwrt_release
log "系统: ${DISTRIB_RELEASE:-unknown} / ${DISTRIB_ARCH:-unknown} / ${DISTRIB_TARGET:-unknown}"

case "${DISTRIB_RELEASE:-}" in
  25.12*) ;;
  *) warn "官方 feed 只支持 OpenWrt 25.12（内核 6.12+）。当前为 ${DISTRIB_RELEASE:-unknown}，安装可能失败。" ;;
esac

if [ -n "${DISTRIB_ARCH:-}" ] && [ "${DISTRIB_ARCH}" != "${HONK_BUILD_ARCH}" ] && [ "${HONK_BUILD_ARCH}" != "unknown" ]; then
  if [ "${ALLOW_ARCH_MISMATCH}" -eq 1 ]; then
    warn "架构不匹配：本包为 ${HONK_BUILD_ARCH}，设备为 ${DISTRIB_ARCH}；已按 --force 继续，安装很可能失败。"
  else
    die "架构不匹配：本包为 ${HONK_BUILD_ARCH}，设备为 ${DISTRIB_ARCH}。请下载与 DISTRIB_ARCH 一致的 .run；确认强制安装请加 --force。"
  fi
fi

if [ -x /etc/init.d/dae ] && /etc/init.d/dae running >/dev/null 2>&1; then
  warn "检测到 dae 服务正在运行。dae 与 honk 不能同时运行（两者都接管 eBPF 数据面）。"
  warn "请先执行： /etc/init.d/dae stop && /etc/init.d/dae disable"
  die "已中止，未做任何更改。"
fi

setup_feed() {
  mkdir -p /etc/apk/keys /etc/apk/repositories.d
  FEED_ROOT="$(printf '%s' "${HONK_BUILD_FEED}" | sed 's|/packages/*$||')"
  log "导入 feed 签名公钥 ..."
  tmp_key="$(mktemp "${TMPDIR:-/tmp}/daeuniverse-key.XXXXXX")" || die "无法创建临时文件。"
  if ! wget -qO "$tmp_key" "$FEED_KEY_URL"; then
    rm -f "$tmp_key"
    die "下载签名公钥失败，请检查网络连通性。"
  fi
  actual_key="$(sha256sum "$tmp_key" | cut -d' ' -f1)"
  if [ "$actual_key" != "$FEED_KEY_SHA256" ]; then
    warn "feed 公钥指纹与固定值不一致（期望 ${FEED_KEY_SHA256}，实际 ${actual_key}）。"
    warn "可能上游已轮换密钥，也可能是中间人替换；将继续使用该公钥。如确认已轮换，可设 HONK_FEED_KEY_SHA256=<新指纹> 消除告警。"
  fi
  mv "$tmp_key" /etc/apk/keys/daeuniverse.pem || { rm -f "$tmp_key"; die "无法写入 /etc/apk/keys/daeuniverse.pem。"; }
  {
    printf '@daeuniverse %s/packages/%s/packages.adb\n' "${FEED_ROOT}" "${DISTRIB_ARCH}"
    if [ ! -f /sys/kernel/btf/vmlinux ]; then
      printf '@daeuniverse %s/kmods/%s/%s/packages.adb\n' "${FEED_ROOT}" "${DISTRIB_RELEASE}" "${DISTRIB_TARGET}"
    fi
  } > /etc/apk/repositories.d/daeuniverse.list
  log "已写入 /etc/apk/repositories.d/daeuniverse.list"
  log "内核 BTF: $([ -f /sys/kernel/btf/vmlinux ] && echo '内建' || echo '需要 kmods 仓库提供')"
  apk update || die "apk update 失败，请检查网络与 feed 地址。"
}

install_online() {
  setup_feed
  PKGS="honk@daeuniverse"
  if [ "${WITH_LUCI}" -eq 1 ]; then
    PKGS="${PKGS} luci-app-honk@daeuniverse luci-lib-daeuniverse@daeuniverse"
  fi
  log "执行: apk add ${PKGS}"
  # shellcheck disable=SC2086
  apk add ${PKGS} || die "在线安装失败，详见上面的 apk 输出。"
  if [ ! -f /sys/kernel/btf/vmlinux ]; then
    apk add vmlinux-btf@daeuniverse || warn "vmlinux-btf 安装失败；官方 OpenWrt 内核无 BTF，honk 将无法启动。"
  fi
  apk add v2ray-geoip v2ray-geosite 2>/dev/null || warn "v2ray-geoip / v2ray-geosite 未安装（通常由系统源提供）。"
  if [ "${WITH_LUCI}" -eq 1 ]; then
    apk add luci-i18n-daeuniverse-zh-cn@daeuniverse 2>/dev/null || true
  fi
  log "在线安装完成，后续升级可直接执行: apk update && apk upgrade honk luci-app-honk"
}

install_offline() {
  persist="/etc/honk/apks"
  mkdir -p "$persist" || die "无法创建 $persist"
  set --
  for f in "${SELF_DIR}"/*.apk; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
      luci-app-honk-*|luci-lib-daeuniverse-*|luci-i18n-*)
        [ "${WITH_LUCI}" -eq 1 ] || continue
        ;;
    esac
    cp -f "$f" "$persist/" || die "无法复制 $(basename "$f") 到 $persist"
    set -- "$@" "$persist/$(basename "$f")"
  done
  [ "$#" -gt 0 ] || die "包内没有可安装的 .apk 文件。"
  log "已将 $# 个 apk 复制到 $persist（持久保存，避免 world 指向已删除的临时目录）"
  log "执行: apk add --allow-untrusted $persist/*.apk"
  apk add --allow-untrusted "$@" || die "离线安装失败：可能缺少依赖（如 v2ray-geoip / v2ray-geosite / vmlinux-btf）。请改用默认的在线模式。"
  warn "离线安装会把 honk 固定到 $persist 下的本地文件，之后 'apk add' 可能报 breaks: world。"
  warn "联网后请执行一次: apk add honk@daeuniverse luci-app-honk@daeuniverse 以解除固定。"
}

if [ "${MODE}" = "offline" ]; then
  install_offline
else
  install_online
fi

log "安装完成。"
log "配置文件: /etc/honk/config.dae （默认 LAN 接口为 br-lan，请先按实际网卡修改）"
log "官方文档: https://daeuniverse.org/openwrt/"
if [ "${ENABLE}" -eq 1 ]; then
  /etc/init.d/honk enable && /etc/init.d/honk start || warn "服务启动失败，请检查日志与内核 BTF。"
  log "服务已启动。doona 界面: http://<路由器LAN IP>:9527/"
else
  log "未自动启动服务（首次部署会修改网络 hook / 命名空间 / sysctl，保留带外管理通道更安全）。"
  log "确认配置后再执行: /etc/init.d/honk enable && /etc/init.d/honk start"
fi
exit 0
