#!/usr/bin/env bash
# One command to validate a change before you test on a device:
#   ./tests/run.sh
# 1) Lua syntax of every plugin file  2) every _("...") has a French entry
# in l10n.lua (and no orphan entry)  3) logic tests (tests/*_spec.lua)
set -u
cd "$(dirname "$0")/.."
fail=0

LUA=""; for c in luajit lua5.1 lua; do command -v "$c" >/dev/null 2>&1 && LUA="$c" && break; done
[ -z "$LUA" ] && { echo "No Lua interpreter found (install lua5.1 or luajit)"; exit 2; }

echo "== 1. Syntax ($LUA)"
for f in *.lua tests/*.lua; do
  if ! "$LUA" -e "assert(loadfile('$f'))" 2>/tmp/cls_syntax_err; then
    echo "  SYNTAX ERROR in $f: $(cat /tmp/cls_syntax_err)"; fail=1
  fi
done
[ $fail -eq 0 ] && echo "  ok"

echo "== 2. l10n coverage"
grep -ohE '_\("([^"\\]|\\.)*"\)' main.lua syncengine.lua webdavapi.lua 2>/dev/null \
  | sed -E 's/^_\(//; s/\)$//' | sort -u > /tmp/cls_used.txt
grep -oE '^\s*\["([^"\\]|\\.)*"\]' l10n.lua | sed -E 's/^\s*\[//; s/\]$//' | sort -u > /tmp/cls_dict.txt
missing=$(comm -23 /tmp/cls_used.txt /tmp/cls_dict.txt)
orphan=$(comm -13 /tmp/cls_used.txt /tmp/cls_dict.txt)
[ -n "$missing" ] && { echo "  MISSING French entry for:"; echo "$missing" | sed 's/^/    /'; fail=1; }
[ -n "$orphan" ]  && { echo "  ORPHAN entry (unused string) in l10n.lua:"; echo "$orphan" | sed 's/^/    /'; }
[ -z "$missing" ] && [ -z "$orphan" ] && echo "  ok"

echo "== 3. Logic tests"
for spec in tests/*_spec.lua; do
  echo "-- $spec"
  "$LUA" "$spec" || fail=1
done

echo
[ $fail -eq 0 ] && echo "ALL GOOD" || echo "PROBLEMS FOUND"
exit $fail
