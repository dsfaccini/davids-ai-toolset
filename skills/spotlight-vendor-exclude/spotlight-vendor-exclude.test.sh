#!/usr/bin/env bash
# Checks the spotlight-vendor-exclude skill: frontmatter, folder detection, and the plist sync on macOS.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL="$DIR/SKILL.md"
SVE="$DIR/scripts/spotlight-vendor-exclude"
fails=0

check() { # <label> <command...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok   $label"; else echo "FAIL $label"; fails=$((fails + 1)); fi
}

front=$(awk 'NR==1&&$0!="---"{exit} NR>1&&$0=="---"{exit} NR>1{print}' "$SKILL")
name=$(printf '%s\n' "$front" | sed -n 's/^name: *//p')
desc=$(printf '%s\n' "$front" | sed -n 's/^description: *//p')
check "name matches the folder" test "$name" = "$(basename "$DIR")"
check "description says when to load" grep -qi 'load when' <<<"$desc"
check "description says when to skip" grep -qi 'skip' <<<"$desc"
check "script parses" bash -n "$SVE"
check "no home paths" bash -c "! grep -rnE '/(Users|home)/[a-z]' '$DIR'"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
R=$T/home
files() { mkdir -p "$1"; for f in a b c; do echo x >"$1/$f"; done; }
files "$R/app/node_modules/pkg"
mkdir -p "$R/small/node_modules"; echo x >"$R/small/node_modules/a"
git init -q "$R/repo"; echo 'dist/' >"$R/repo/.gitignore"
files "$R/repo/dist"; files "$R/repo/build"
files "$R/rs/target/debug"; touch "$R/rs/target/CACHEDIR.TAG"
files "$R/gomod/vendor/x"; touch "$R/gomod/vendor/modules.txt"
files "$R/py/venv/lib"; touch "$R/py/venv/pyvenv.cfg"; files "$R/py/venv/lib/build"
files "$R/.hidden/node_modules"
files "$R/Library/app/node_modules"; files "$R/Library/pnpm/store"
files "$R/go/pkg/mod/m/vendor"; touch "$R/go/pkg/mod/m/vendor/modules.txt"

got=$(MIN_FILES=3 "$SVE" list "$R" | sed "s#^$R/##")
want='Library/pnpm/store
app/node_modules
go/pkg/mod
gomod/vendor
py/venv
repo/dist
rs/target'
check "list finds exactly the vendor folders" test "$got" = "$want"
[ "$got" = "$want" ] || diff <(echo "$want") <(echo "$got")

if command -v plutil >/dev/null; then
  export SVE_PLIST=$T/vc.plist SVE_STATE=$T/added.txt MIN_FILES=3
  plutil -create xml1 "$SVE_PLIST"
  plutil -insert Exclusions -array "$SVE_PLIST"
  plutil -insert Exclusions -string /by-hand -append "$SVE_PLIST"
  entries() { plutil -extract Exclusions json -o - "$SVE_PLIST" | tr ',' '\n' | grep -c '"'; }
  "$SVE" apply "$R" >/dev/null
  check "apply adds every folder and keeps the hand entry" test "$(entries)" -eq 8
  "$SVE" apply "$R" >/dev/null
  check "apply is idempotent" test "$(entries)" -eq 8
  rm -rf "$R/app/node_modules"
  "$SVE" apply "$R" >/dev/null
  check "apply drops a deleted folder" test "$(entries)" -eq 7
  "$SVE" uninstall >/dev/null
  check "uninstall leaves only the hand entry" test "$(plutil -extract Exclusions.0 raw -o - "$SVE_PLIST")" = /by-hand
  check "uninstall removes one entry per folder" test "$(entries)" -eq 1
else
  echo "skip plist sync checks: no plutil"
fi

[ "$fails" -eq 0 ] && echo "all checks pass" || { echo "$fails checks failed"; exit 1; }
