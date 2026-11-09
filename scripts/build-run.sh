#!/usr/bin/env bash
# Build honk .run self-extracting installers from the daeuniverse OpenWrt apk feed.
# Runs on a GitHub Actions ubuntu runner (or any bash + curl + tar host).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

FEED_BASE="${FEED_BASE:-https://openwrt.daeuniverse.org/25.12/packages}"
OWRT_RELEASE="${OWRT_RELEASE:-25.12}"
OUT_DIR="${OUT_DIR:-dist/honk-run}"
ALL_ARCHES=(x86_64 aarch64_generic aarch64_cortex-a53 aarch64_cortex-a72 aarch64_cortex-a76)

REQUIRED_PREFIXES=("honk-" "luci-app-honk-")
OPTIONAL_PREFIXES=("luci-lib-daeuniverse-" "luci-i18n-daeuniverse-zh-cn-" "luci-i18n-daeuniverse-zh-tw-")

NO_PACKAGE=0
TARGET_ARCHES=()
TMP_ROOT=""

log()  { printf '==> %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: bash scripts/build-run.sh --all [--no-package]
      bash scripts/build-run.sh --arch x86_64 --arch aarch64_generic

  --all            构建全部 5 个架构
  --arch NAME      只构建指定架构（可重复）
  --out DIR        产物目录（默认 dist/honk-run）
  --feed URL       apk feed 根地址（默认 daeuniverse 25.12 packages）
  --no-package     只下载 apk 并生成清单，不生成 .run（用于本地验证）
  --help           显示帮助

环境变量: FEED_BASE, OWRT_RELEASE, OUT_DIR 可覆盖默认值。
EOF
}

pick_one() {
  local prefix="$1" f best=""
  shift
  for f in "$@"; do
    case "$f" in
      "${prefix}"*.apk) best="$f" ;;
    esac
  done
  printf '%s' "$best"
}

build_selfextracting() {
  local stage="$1" out="$2" name="$3" arch="$4"
  local payload="$TMP_ROOT/payload-$arch.tar.gz" header="$TMP_ROOT/header-$arch.sh"
  local base="${name%.run}" n=0 i new

  # --force-local keeps GNU tar from reading a Windows drive letter as a remote host.
  tar --force-local -czf "$payload" -C "$stage" . || return 1
  # The header stores its own byte length; iterate until the length is stable.
  for i in 1 2 3 4 5; do
    sed -e "s|@@BASENAME@@|${base}|g" -e "s|@@OFFSET@@|${n}|g" \
      "$SCRIPT_DIR/run-header.sh" > "$header" || return 1
    new="$(wc -c < "$header" | tr -d '[:space:]')"
    if [ "$new" = "$n" ]; then break; fi
    n="$new"
  done
  cat "$header" "$payload" > "$out" || return 1
  chmod 755 "$out"
}

build_one() {
  local arch="$1"
  local index="$TMP_ROOT/index-$arch.html"
  local dl="$OUT_DIR/apk/$arch" stage="$TMP_ROOT/stage-$arch"
  local apk_files=() pkg_list=() f prefix version run_name run_path size

  mkdir -p "$dl" "$stage" "$OUT_DIR/run"

  log "[$arch] 抓取索引 ${FEED_BASE}/${arch}/"
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 60 \
    "${FEED_BASE}/${arch}/" -o "$index" || die "[$arch] 索引下载失败"

  mapfile -t apk_files < <(grep -o 'href="[^"]*\.apk"' "$index" \
    | sed -E 's/^href="([^"]+)"$/\1/' | LC_ALL=C sort -u)
  [ "${#apk_files[@]}" -gt 0 ] || die "[$arch] 索引里没有 .apk 文件"

  for prefix in "${REQUIRED_PREFIXES[@]}"; do
    f="$(pick_one "$prefix" "${apk_files[@]}")"
    [ -n "$f" ] || die "[$arch] feed 中缺少必需包: ${prefix}*.apk"
    pkg_list+=("$f")
  done
  for prefix in "${OPTIONAL_PREFIXES[@]}"; do
    f="$(pick_one "$prefix" "${apk_files[@]}")"
    if [ -n "$f" ]; then pkg_list+=("$f"); fi
  done

  version="${pkg_list[0]#honk-}"
  version="${version%.apk}"
  log "[$arch] honk 版本 ${version}，共 ${#pkg_list[@]} 个 apk"

  for f in "${pkg_list[@]}"; do
    if [ -s "${dl}/${f}" ] && [ "$(wc -c < "${dl}/${f}" | tr -d '[:space:]')" -gt 1024 ]; then
      log "[$arch] 已缓存 $f"
      continue
    fi
    log "[$arch] 下载 $f"
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 600 \
      "${FEED_BASE}/${arch}/${f}" -o "${dl}/${f}" || die "[$arch] 下载失败: $f"
    size="$(wc -c < "${dl}/${f}" | tr -d '[:space:]')"
    [ "$size" -gt 1024 ] || die "[$arch] 文件异常小: $f ($size bytes)"
  done

  cp "${dl}"/*.apk "$stage/"
  cp "$SCRIPT_DIR/install.sh" "$stage/install.sh"
  chmod 755 "$stage/install.sh"
  cat > "$stage/build-info.sh" <<EOF
HONK_BUILD_VERSION="${version}"
HONK_BUILD_ARCH="${arch}"
HONK_BUILD_FEED="${FEED_BASE}"
HONK_BUILD_DATE="$(date -u +%Y-%m-%d)"
HONK_BUILD_PACKAGES="$(printf '%s ' "${pkg_list[@]}")"
EOF

  run_name="25_honk_${version}_${arch}.run"
  run_path="$OUT_DIR/run/$run_name"
  if [ "$NO_PACKAGE" -eq 1 ]; then
    log "[$arch] --no-package：跳过打包"
  elif command -v makeself >/dev/null 2>&1; then
    if makeself "$stage" "$run_path" \
        "honk ${version} for ${arch} / OpenWrt ${OWRT_RELEASE}" ./install.sh; then
      log "[$arch] 生成 $run_name (makeself)"
    else
      warn "[$arch] makeself 打包失败，回退到内置自解压头"
      rm -f "$run_path"
      build_selfextracting "$stage" "$run_path" "$run_name" "$arch" \
        || die "[$arch] 回退打包也失败"
      log "[$arch] 生成 $run_name (内置自解压 / makeself 回退)"
    fi
  else
    build_selfextracting "$stage" "$run_path" "$run_name" "$arch" \
      || die "[$arch] 内置自解压打包失败"
    log "[$arch] 生成 $run_name (内置自解压，未检测到 makeself)"
  fi
}

write_meta() {
  local f rel first_version="" date_tag run_base arch_label
  for f in "$OUT_DIR"/apk/*/honk-*.apk; do
    if [ -f "$f" ]; then
      first_version="$(basename "$f")"
      first_version="${first_version#honk-}"
      first_version="${first_version%.apk}"
      break
    fi
  done
  [ -n "$first_version" ] || die "未能从下载结果确定 honk 版本"

  printf '%s\n' "$first_version" > "$OUT_DIR/version.txt"
  date_tag="$(date -u +%Y%m%d)"
  printf 'honk-%s-%s\n' "$first_version" "$date_tag" > "$OUT_DIR/archive-tag.txt"

  {
    printf 'schema=1\n'
    printf 'generated_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'openwrt_release=%s\n' "$OWRT_RELEASE"
    printf 'feed=%s\n' "$FEED_BASE"
    printf 'honk_version=%s\n' "$first_version"
    printf 'arches=%s\n' "${TARGET_ARCHES[*]}"
    printf '\n[packages]\n'
    for f in "$OUT_DIR"/apk/*/*.apk; do
      [ -f "$f" ] || continue
      printf '%s/%s %s bytes\n' "$(basename "$(dirname "$f")")" "$(basename "$f")" \
        "$(wc -c < "$f" | tr -d '[:space:]')"
    done
    printf '\n[run files]\n'
    for f in "$OUT_DIR"/run/*.run; do
      [ -f "$f" ] || continue
      printf '%s %s bytes\n' "$(basename "$f")" "$(wc -c < "$f" | tr -d '[:space:]')"
    done
  } > "$OUT_DIR/manifest.txt"

  {
    printf 'feed=%s\n' "$FEED_BASE"
    printf 'openwrt=%s\n' "$OWRT_RELEASE"
    for f in "$OUT_DIR"/apk/*/*.apk; do
      [ -f "$f" ] || continue
      rel="${f#${OUT_DIR}/apk/}"
      printf '%s %s\n' "$rel" "$(wc -c < "$f" | tr -d '[:space:]')"
    done
  } | LC_ALL=C sort | sha256sum | cut -d' ' -f1 > "$OUT_DIR/fingerprint.txt"

  : > "$OUT_DIR/SHA256SUMS"
  for f in "$OUT_DIR"/run/*.run; do
    [ -f "$f" ] || continue
    ( cd "$OUT_DIR/run" && sha256sum "$(basename "$f")" ) >> "$OUT_DIR/SHA256SUMS"
  done

  {
    cat <<EOF
## honk .run 自动构建

- honk 版本：**${first_version}**
- 目标系统：OpenWrt / ImmortalWrt **${OWRT_RELEASE}**（apk 体系，内核 6.12+）
- 数据来源：${FEED_BASE}
- 构建时间（UTC）：$(date -u +%Y-%m-%dT%H:%M:%SZ)
- 包内组件：honk、luci-app-honk、luci-lib-daeuniverse、中文/繁中语言包

### 下载

| 架构 | 文件 |
| --- | --- |
EOF
    for f in "$OUT_DIR"/run/*.run; do
      [ -f "$f" ] || continue
      run_base="$(basename "$f")"
      arch_label="${run_base#25_honk_${first_version}_}"
      arch_label="${arch_label%.run}"
      printf '| %s | %s |\n' "$arch_label" "$run_base"
    done
    cat <<'EOF'

架构名以 `DISTRIB_ARCH` 为准，路由器上执行 `. /etc/openwrt_release && echo $DISTRIB_ARCH` 查看。

### 安装

```
wget -O honk.run <对应架构的 .run 下载地址>
sh honk.run
```

- 默认走在线模式：自动配置 daeuniverse 官方 apk 源并安装，后续可直接 `apk upgrade`。
- 无网络时用 `sh honk.run -- --offline` 安装包内 apk（会被 pin，联网后需解 pin）。
- 只解压不安装：`sh honk.run --target /tmp/honk --noexec`
- 默认**不**自动启动服务。确认 `/etc/honk/config.dae` 后再执行
  `/etc/init.d/honk enable && /etc/init.d/honk start`。
- dae 与 honk 不能同时运行，安装前请先停用 dae。

校验：`sha256sum -c SHA256SUMS`

详细文档：https://daeuniverse.org/openwrt/
EOF
  } > "$OUT_DIR/RELEASE.md"

  log "版本 ${first_version} / 指纹 $(cat "$OUT_DIR/fingerprint.txt")"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all) TARGET_ARCHES=("${ALL_ARCHES[@]}"); shift ;;
    --arch)
      [ "$#" -ge 2 ] || die "--arch 需要参数"
      TARGET_ARCHES+=("$2"); shift 2 ;;
    --out)
      [ "$#" -ge 2 ] || die "--out 需要参数"
      OUT_DIR="$2"; shift 2 ;;
    --feed)
      [ "$#" -ge 2 ] || die "--feed 需要参数"
      FEED_BASE="$2"; shift 2 ;;
    --no-package) NO_PACKAGE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "未知参数: $1 （用 --help 查看用法）" ;;
  esac
done

if [ "${#TARGET_ARCHES[@]}" -eq 0 ]; then
  usage
  exit 0
fi

mkdir -p "$OUT_DIR" dist
# Keep scratch paths relative so GNU tar never sees a Windows drive letter in -f.
TMP_ROOT="$(mktemp -d dist/.honkrun-build.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM
for arch in "${TARGET_ARCHES[@]}"; do
  build_one "$arch"
done
write_meta
log "完成，产物位于 $OUT_DIR"
