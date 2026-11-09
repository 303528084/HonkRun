#!/usr/bin/env bash
# Smoke test: unpack every generated .run with --noexec and check its contents.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"
OUT_DIR="${OUT_DIR:-dist/honk-run}"

log() { printf '==> %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

shopt -s nullglob
runs=("$OUT_DIR"/run/*.run)
[ "${#runs[@]}" -gt 0 ] || die "没有找到 .run 产物：$OUT_DIR/run/"

mkdir -p dist
TMP_ROOT="$(mktemp -d dist/.honkrun-verify.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

for run in "${runs[@]}"; do
  name="$(basename "$run")"
  dest="$TMP_ROOT/${name%.run}"
  log "校验 $name"
  sh "$run" --target "$dest" --noexec > "$TMP_ROOT/extract.log" 2>&1 \
    || { cat "$TMP_ROOT/extract.log" >&2; die "$name 解压失败"; }

  [ -f "$dest/install.sh" ] || die "$name 缺少 install.sh"
  [ -f "$dest/build-info.sh" ] || die "$name 缺少 build-info.sh"
  apk_count="$(find "$dest" -maxdepth 1 -type f -name '*.apk' | wc -l | tr -d '[:space:]')"
  [ "$apk_count" -ge 2 ] || die "$name 内 apk 数量不足（$apk_count）"

  ( cd "$dest" && sh ./install.sh --help ) > "$TMP_ROOT/help.txt" 2>&1 \
    || { cat "$TMP_ROOT/help.txt" >&2; die "$name 的 install.sh 无法执行"; }
  grep -q '用法' "$TMP_ROOT/help.txt" || die "$name 的 install.sh 帮助输出异常"

  log "  OK：$apk_count 个 apk，install.sh 可执行"
done

if [ -s "$OUT_DIR/SHA256SUMS" ]; then
  ( cd "$OUT_DIR/run" && sha256sum -c ../SHA256SUMS ) || die "SHA256SUMS 校验失败"
  log "SHA256SUMS 校验通过"
fi

log "全部 ${#runs[@]} 个 .run 包校验通过"
