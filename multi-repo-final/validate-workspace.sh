#!/usr/bin/env bash
#
# validate-workspace.sh - Multi-repository workspace gate validator
#
# Usage:
#   validate-workspace.sh <artifacts_folder> [all|map|cleanup]
#
# <artifacts_folder> is the application's artifacts folder, e.g. artifacts/Liqor
# It must contain workspace.json (written by workspace-mapper), which names the
# codebase root the repositories live under.
#
# Examples:
#   validate-workspace.sh artifacts/Liqor map
#   validate-workspace.sh artifacts/Liqor cleanup
#   validate-workspace.sh artifacts/Liqor all
#
# Output files (written automatically alongside stdout):
#   map      -> {artifacts_folder}/validate-map.txt
#   cleanup  -> {artifacts_folder}/validate-cleanup.txt
#   all      -> {artifacts_folder}/validate-workspace.txt
#
# Exit codes: 0 = PASS/WARN only, 1 = any FAIL, 2 = bad arguments

set -u

FOLDER="${1?Usage: validate-workspace.sh <artifacts_folder> [all|map|cleanup]}"
GATE="${2:-all}"
FOLDER="${FOLDER%/}"
APP_NAME="$(basename "$FOLDER")"

WS="$FOLDER/workspace.json"
SM="$FOLDER/source-map.json"

TOTAL_PASS=0
TOTAL_WARN=0
TOTAL_FAIL=0

# ---- determine output file -------------------------------------------------

case "$GATE" in
  map)     OUTFILE="$FOLDER/validate-map.txt" ;;
  cleanup) OUTFILE="$FOLDER/validate-cleanup.txt" ;;
  all)     OUTFILE="$FOLDER/validate-workspace.txt" ;;
  *)
    echo "Unknown gate '$GATE'. Valid: map cleanup all" >&2
    exit 2
    ;;
esac

if [ ! -d "$FOLDER" ]; then
  echo "Artifacts folder not found: $FOLDER" >&2
  exit 2
fi

# Open fd 3 -> output file (plain, no ANSI). All helpers write to both.
mkdir -p "$(dirname "$OUTFILE")"
exec 3>"$OUTFILE"

# ---- output helpers --------------------------------------------------------

_out() {
  printf "%s\n" "$1"
  printf "%s\n" "$1" >&3
}

_sep() {
  printf "%.60s\n" "------------------------------------------------------------"
  printf "%.60s\n" "------------------------------------------------------------" >&3
  printf "\n"
  printf "\n" >&3
}

_pass() {
  printf "\033[32mPASS\033[0m %s\n" "$1"
  printf " PASS %s\n" "$1" >&3
  TOTAL_PASS=$((TOTAL_PASS+1))
}

_warn() {
  printf "\033[33mWARN\033[0m %s\n" "$1"
  printf " WARN %s\n" "$1" >&3
  TOTAL_WARN=$((TOTAL_WARN+1))
}

_fail() {
  printf "\033[31mFAIL\033[0m %s\n" "$1"
  printf " FAIL %s\n" "$1" >&3
  TOTAL_FAIL=$((TOTAL_FAIL+1))
}

# ---- grep helpers ----------------------------------------------------------

_count() {
  grep -cE "$1" "$2" 2>/dev/null || echo 0
}

_has() {
  grep -qF -- "$1" "$2" 2>/dev/null
}

# Values of a string key, in file order:   _values '"folder"' file
_values() {
  grep -oE "$1[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$2" 2>/dev/null \
    | sed -E 's/^[^:]*:[[:space:]]*"//; s/"$//'
}

# Same, but from a string instead of a file
_values_in() {
  printf "%s\n" "$2" | grep -oE "$1[[:space:]]*:[[:space:]]*\"[^\"]*\"" 2>/dev/null \
    | sed -E 's/^[^:]*:[[:space:]]*"//; s/"$//'
}

# Lines between the line containing $1 and the next line that is exactly
# two spaces + "]" or "]," — a top-level array in 2-space-indented JSON.
_block() {
  awk -v key="$1" '
    found==0 && index($0,key)>0 {
      if ($0 ~ /\][[:space:]]*,?[[:space:]]*$/) exit      # inline "[]" or "[ ... ]" — empty block
      match($0, /^[[:space:]]*/); indent=substr($0, 1, RLENGTH)
      found=1; next
    }
    found==1 && index($0, indent "]")==1 && substr($0, length(indent)+1) ~ /^\],?[[:space:]]*$/ {exit}
    found==1 {print}
  ' "$2" 2>/dev/null
}

# Same as _block, but for an inline array key inside a source block: prints the
# quoted items of the array whether it is written on one line or several.
_array_items() {
  awk -v key="$1" '
    found==0 && index($0,key)>0 {
      line=$0; sub(/^[^\[]*\[/, "", line)
      if (line ~ /\]/) { sub(/\].*$/, "", line); print line; next }
      print line; found=1; next
    }
    found==1 && /\]/ { sub(/\].*$/, ""); print; found=0; next }
    found==1 {print}
  ' "$2" 2>/dev/null | grep -oE '"[^"]+"' | tr -d '"'
}

# Does $1 appear as a whole line in the newline-separated list $2
_in_list() {
  printf "%s\n" "$2" | grep -qxF -- "$1"
}

# ---- resolve codebase root (needed by both gates) ---------------------------

CODEBASE=""
if [ -f "$WS" ]; then
  CODEBASE="$(_values '"codebase_root"' "$WS" | head -1)"
  CODEBASE="${CODEBASE%/}"
fi

# ---- Gate M: workspace.json -----------------------------------------------

gate_map() {
  _out ""
  _out "Gate M — workspace.json:"
  _out ""

  if [ ! -f "$WS" ] || [ ! -s "$WS" ]; then
    _fail "workspace.json missing or empty"
    return
  fi

  local key
  for key in '"application"' '"key_prefix"' '"codebase_root"' '"repositories"' '"cross_references"'; do
    if _has "$key" "$WS"; then
      _pass "has $key"
    else
      _fail "missing top-level key $key"
    fi
  done

  local kp slashes
  kp="$(_values '"key_prefix"' "$WS" | head -1)"
  slashes="$(printf "%s" "$kp" | tr -cd '/' | wc -c | tr -d ' ')"
  if [ "$slashes" -eq 2 ] && [ -n "$kp" ] && ! printf "%s" "$kp" | grep -qE '(^/|//|/$)'; then
    _pass "key_prefix '$kp' has 3 segments"
  else
    _fail "key_prefix '$kp' must be org/project/service"
  fi

  if [ -n "$CODEBASE" ] && [ -d "$CODEBASE" ]; then
    _pass "codebase_root exists: $CODEBASE"
  else
    _fail "codebase_root '$CODEBASE' not found on disk"
    return
  fi

  local repos_block
  repos_block="$(_block '"repositories": [' "$WS")"
  if [ -z "$repos_block" ]; then
    _fail "repositories block empty or not found"
    return
  fi

  local folders kinds lives n_folders
  folders="$(_values_in '"folder"' "$repos_block")"
  kinds="$(_values_in '"kind"' "$repos_block")"
  lives="$(printf "%s\n" "$repos_block" | grep -oE '"live"[[:space:]]*:[[:space:]]*(true|false)' | sed -E 's/^[^:]*:[[:space:]]*//')"
  n_folders="$(printf "%s\n" "$folders" | grep -c . || true)"
  if [ "$n_folders" -eq 0 ]; then
    _fail "no repositories listed"
    return
  fi
  _pass "$n_folders repositories listed"

  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      /*|./*|*..*|*:*) _fail "$f: folder must be a plain child name under codebase_root" ;;
      */*)             _fail "$f: repository is nested inside another folder — flatten it" ;;
    esac
    if [ -d "$CODEBASE/$f" ]; then
      _pass "$f: folder exists"
    else
      _fail "$f: folder missing under $CODEBASE"
    fi
  done <<< "$folders"

  local k
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    case "$k" in
      application-code|shared-library|database|import-config|reports|tests|docs) _pass "kind '$k'" ;;
      *) _fail "kind '$k' not allowed (application-code shared-library database import-config reports tests docs)" ;;
    esac
  done <<< "$kinds"

  if printf "%s\n" "$lives" | grep -qx false; then
    _fail "an entry under 'repositories' has live: false — retired copies belong under 'retired'"
  else
    _pass "all listed repositories are live"
  fi

  local n_rev n_asof
  n_rev="$(printf "%s\n" "$repos_block" | grep -cE '"revision"[[:space:]]*:[[:space:]]*"(git|zip):' || true)"
  n_asof="$(printf "%s\n" "$repos_block" | grep -cE '"as_of"[[:space:]]*:[[:space:]]*"[0-9]{4}-[0-9]{2}-[0-9]{2}"' || true)"
  if [ "$n_rev" -eq "$n_folders" ]; then
    _pass "revision recorded for every repository"
  else
    _warn "revision recorded for $n_rev of $n_folders repositories (expected git:... or zip:...)"
  fi
  if [ "$n_asof" -eq "$n_folders" ]; then
    _pass "as_of recorded for every repository"
  else
    _warn "as_of recorded for $n_asof of $n_folders repositories"
  fi

  local retired_block sup
  retired_block="$(_block '"retired": [' "$WS")"
  while IFS= read -r sup; do
    [ -n "$sup" ] || continue
    if _in_list "$sup" "$folders"; then
      _pass "retired entry superseded by live repository '$sup'"
    else
      _fail "retired entry: superseded_by '$sup' is not a live repository"
    fi
  done <<< "$(_values_in '"superseded_by"' "$retired_block")"

  local retired_folders wrappers excluded_heads d name
  retired_folders="$(_values_in '"folder"' "$retired_block")"
  wrappers="$(_values_in '"outer"' "$(_block '"wrappers": [' "$WS")")"
  excluded_heads="$(_block '"excluded": [' "$WS" | grep -oE '"[^"]+"' | tr -d '"' | sed -E 's#/.*$##')"
  for d in "$CODEBASE"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    [ "$name" = "_excluded" ] && continue
    if _in_list "$name" "$folders" || _in_list "$name" "$retired_folders" \
       || _in_list "$name" "$wrappers" || _in_list "$name" "$excluded_heads"; then
      continue
    fi
    _warn "top-level folder '$name' is not declared, retired, wrapped, or excluded — stray download?"
  done

  local xr_block p
  xr_block="$(awk '/"cross_references": \{/{f=1} f{print}' "$WS")"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -e "$CODEBASE/$p" ]; then
      _pass "cross-reference path exists: $p"
    else
      _fail "cross-reference path missing: $p"
    fi
  done <<< "$(printf "%s\n" "$xr_block" | grep -oE '"(definition|workflow|at)"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/^[^:]*:[[:space:]]*"//; s/"$//' | sort -u)"

  local n_unres n_notices
  n_unres="$(_block '"unresolvable": [' "$WS" | grep -c '"text"' || true)"
  [ "$n_unres" -gt 0 ] && _warn "$n_unres unresolvable cross-references (see cross_references.unresolvable)"
  n_notices="$(_block '"notices": [' "$WS" | grep -c '"type"' || true)"
  [ "$n_notices" -gt 0 ] && _warn "$n_notices notices (see workspace.json → notices)"

  if [ -f "$FOLDER/workspace-map.md" ]; then
    _pass "workspace-map.md present"
  else
    _fail "workspace-map.md missing"
  fi
}

# ---- Gate C: source-map.json after cleanup --------------------------------

gate_cleanup() {
  _out ""
  _out "Gate C — source-map.json (cleaned):"
  _out ""

  if [ ! -f "$WS" ]; then
    _fail "workspace.json missing — cannot validate cleanup without it"
    return
  fi
  if [ -z "$CODEBASE" ] || [ ! -d "$CODEBASE" ]; then
    _fail "codebase_root '$CODEBASE' not found on disk"
    return
  fi
  if [ ! -f "$SM" ] || [ ! -s "$SM" ]; then
    _fail "source-map.json missing or empty"
    return
  fi

  if [ -f "$FOLDER/source-map.pre-cleanup.json" ]; then
    _pass "backup source-map.pre-cleanup.json present"
  else
    _fail "source-map.pre-cleanup.json missing — cleanup must back up before writing"
  fi
  if [ -f "$FOLDER/source-map-cleanup.md" ]; then
    _pass "source-map-cleanup.md present"
  else
    _fail "source-map-cleanup.md missing — cleanup pass has not run"
  fi

  local n_sources
  n_sources="$(_count '^    "[A-Za-z0-9_]+": \{' "$SM")"
  if [ "$n_sources" -gt 0 ]; then
    _pass "$n_sources sources"
  else
    _warn "could not count sources (expected 2-space indented JSON)"
  fi

  local live retired
  live="$(_values_in '"folder"' "$(_block '"repositories": [' "$WS")")"
  retired="$(_values_in '"folder"' "$(_block '"retired": [' "$WS")")
$(_values_in '"outer"' "$(_block '"wrappers": [' "$WS")")"

  # every "path" must exist and sit inside a live repository, unless parked
  # (its entry carries a RETIRED / EXCLUDED / UNRESOLVABLE snippet within 2 lines)
  local p top n_bad
  n_bad=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    top="${p%%/*}"
    if grep -A2 -F "\"path\": \"$p\"" "$SM" | grep -qE '"snippet": "(RETIRED|EXCLUDED|UNRESOLVABLE)'; then
      continue
    fi
    if [ ! -e "$CODEBASE/$p" ]; then
      _fail "path does not exist: $p"; n_bad=$((n_bad+1)); continue
    fi
    if _in_list "$top" "$retired"; then
      _fail "path under retired folder '$top' not parked in docs: $p"; n_bad=$((n_bad+1)); continue
    fi
    if ! _in_list "$top" "$live"; then
      _fail "path not inside a live repository ($top): $p"; n_bad=$((n_bad+1)); continue
    fi
  done <<< "$(_values '"path"' "$SM" | sort -u)"
  [ "$n_bad" -eq 0 ] && _pass "all live paths exist and sit inside live repositories"

  local wf_bad
  wf_bad=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ ! -e "$CODEBASE/$p" ]; then
      _fail "workflow_configs entry does not exist: $p"; wf_bad=$((wf_bad+1))
    fi
  done <<< "$(_array_items '"workflow_configs": [' "$SM" | sort -u)"
  [ "$wf_bad" -eq 0 ] && _pass "workflow_configs entries exist"

  # a table the map references must have its DDL (from cross_references) linked
  local tbl_block name def
  tbl_block="$(_block '"tables": [' "$WS")"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    def="$(printf "%s\n" "$tbl_block" | grep -A1 -F "\"name\": \"$name\"" | grep -oE '"definition"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/^[^:]*:[[:space:]]*"//; s/"$//' | head -1)"
    [ -n "$def" ] || continue
    if _has "\"$name\"" "$SM"; then
      if _has "\"path\": \"$def\"" "$SM"; then
        _pass "table $name referenced and its DDL linked"
      else
        _fail "table $name referenced but its DDL not linked: $def"
      fi
    fi
  done <<< "$(_values_in '"name"' "$tbl_block")"

  # a procedure the map names must have its definition linked
  local proc_block
  proc_block="$(_block '"procedures": [' "$WS")"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    def="$(printf "%s\n" "$proc_block" | grep -A1 -F "\"name\": \"$name\"" | grep -oE '"definition"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/^[^:]*:[[:space:]]*"//; s/"$//' | head -1)"
    [ -n "$def" ] || continue
    if _has "$name" "$SM"; then
      if _has "\"path\": \"$def\"" "$SM"; then
        _pass "procedure $name referenced and its definition linked"
      else
        _fail "procedure $name referenced but its definition not linked: $def"
      fi
    fi
  done <<< "$(_values_in '"name"' "$proc_block")"

  # short aliases that survived cleanup
  local a
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    if [ "${#a}" -le 2 ] || printf "%s" "$a" | grep -qE '^[0-9]+$'; then
      _warn "short alias '$a' survived cleanup — confirm the co-occurrence check ran"
    fi
  done <<< "$(_array_items '"aliases": [' "$SM")"
}

# ---- header ------------------------------------------------------------------

_sep
_out "Workspace Gate Validator"
_out "Artifacts: $FOLDER"
_out "App:       $APP_NAME"
_out "Codebase:  ${CODEBASE:-<unresolved>}"
_out "Gate(s):   $GATE"
_out "Output:    $OUTFILE"
_sep

# ---- dispatch ----------------------------------------------------------------

case "$GATE" in
  map)     gate_map ;;
  cleanup) gate_cleanup ;;
  all)
    gate_map
    gate_cleanup
    ;;
esac

_out ""
_sep
printf "Total: \033[32m%d PASS\033[0m  \033[33m%d WARN\033[0m  \033[31m%d FAIL\033[0m\n" \
  "$TOTAL_PASS" "$TOTAL_WARN" "$TOTAL_FAIL"
printf "Total: %d PASS %d WARN %d FAIL\n" \
  "$TOTAL_PASS" "$TOTAL_WARN" "$TOTAL_FAIL" >&3
_sep
_out "Output written to: $OUTFILE"

exec 3>&-

[ "$TOTAL_FAIL" -gt 0 ] && exit 1
exit 0
