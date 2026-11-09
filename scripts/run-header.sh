#!/bin/sh
# Self-extracting header used when makeself is not available.
# scripts/build-run.sh replaces @@OFFSET@@ / @@BASENAME@@ and appends a tar.gz payload.
# Compatible with the common makeself flags: --target DIR, --noexec, --.
set -u

PAYLOAD_OFFSET=@@OFFSET@@
BASENAME="@@BASENAME@@"

SELF="$0"
case "$SELF" in
  /*) ;;
  *) SELF="$(cd "$(dirname "$SELF")" && pwd)/$(basename "$SELF")" ;;
esac

NOEXEC=0
TARGET=""
CLEANUP=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --noexec) NOEXEC=1; shift ;;
    --target)
      [ "$#" -ge 2 ] || { printf '[honk][ERROR] --target 缺少目录参数\n' >&2; exit 2; }
      TARGET="$2"; shift 2 ;;
    --target=*) TARGET="${1#--target=}"; shift ;;
    --) shift; break ;;
    --help|-h) break ;;
    --quiet|-q|--noprogress|--nox11|--nowarn|--nomd5|--nocrc) shift ;;
    -*) shift ;;
    *) break ;;
  esac
done

if [ -z "$TARGET" ]; then
  if [ "$NOEXEC" -eq 1 ]; then
    TARGET="./${BASENAME}"
  else
    TARGET="$(mktemp -d "${TMPDIR:-/tmp}/honkrun.XXXXXX")" || exit 1
    CLEANUP=1
  fi
fi
mkdir -p "$TARGET" || exit 1
TARGET_ABS="$(cd "$TARGET" && pwd)" || exit 1

if ! tail -c +$((PAYLOAD_OFFSET + 1)) "$SELF" | tar -xzf - -C "$TARGET_ABS"; then
  printf '[honk][ERROR] 自解压失败，归档可能已损坏\n' >&2
  exit 1
fi

if [ "$NOEXEC" -eq 1 ]; then
  printf '已解压到: %s（未执行安装）\n' "$TARGET_ABS"
  exit 0
fi

cd "$TARGET_ABS" || exit 1
sh ./install.sh "$@"
status=$?
if [ "$CLEANUP" -eq 1 ]; then
  rm -rf "$TARGET_ABS"
fi
exit "$status"
