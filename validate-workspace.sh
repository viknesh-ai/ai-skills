#!/usr/bin/env bash
#
# validate-workspace.sh - Multi-repository workspace gate validator
#
# Usage:
#   validate-workspace.sh <artifacts_folder> [all|map|link]
#
# <artifacts_folder> is the application's artifacts folder, e.g. artifacts/Liqor
# It must contain workspace.json, which names the codebase root the repositories
# live under.
#
# Examples:
#   validate-workspace.sh artifacts/Liqor map
#   validate-workspace.sh artifacts/Liqor link
#   validate-workspace.sh artifacts/Liqor all
#
# Output files (written automatically alongside stdout):
#   map   -> {artifacts_folder}/validate-map.txt
#   link  -> {artifacts_folder}/validate-link.txt
#   all   -> {artifacts_folder}/validate-workspace.txt
#
# Exit codes: 0 = PASS/WARN only, 1 = any FAIL, 2 = bad arguments

set -u

FOLDER="${1?Usage: validate-workspace.sh <artifacts_folder> [all|map|link]}"
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
  map)  OUTFILE="$FOLDER/validate-map.txt" ;;
  link) OUTFILE="$FOLDER/validate-link.txt" ;;
  all)  OUTFILE="$FOLDER/validate-workspace.txt" ;;
  *)
    echo "Unknown gate '$GATE'. Valid: map link all" >&2
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

_has() {
  grep -qF -- "$1" "$2" 2>/dev/null
}

# Values of a string key in a file:   _values '"folder"' file
_values() {
  grep -oE "$1[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$2" 2>/dev/null \
    | sed -E 's/^[^:]*:[[:space:]]*"//; s/"$//'
}

# Values of a string key in a string
_values_in() {
  printf "%s\n" "$2" | grep -oE "$1[[:space:]]*:[[:space:]]*\"[^\"]*\"" 2>/dev/null \
    | sed -E 's/^[^:]*:[[:space:]]*"//; s/"$//'
}

# Lines of a top-level array: from the line containing $1 to the matching
# closing bracket at the same indent.
_block() {
  awk -v key="$1" '
    found==0 && index($0,key)>0 {
      if ($0 ~ /\][[:space:]]*,?[[:space:]]*$/) exit
      match($0, /^[[:space:]]*/); indent=substr($0, 1, RLENGTH)
      found=1; next
    }
    found==1 && index($0, indent "]")==1 && substr($0, length(indent)+1) ~ /^\],?[[:space:]]*$/ {exit}
    found==1 {print}
  ' "$2" 2>/dev/null
}

# Quoted items of an array key, whether written inline or over several lines
_array_items() {
  awk -v key="$1" '
    found==0 {
      i=index($0,key)
      if (i==0) next
      line=substr($0, i+length(key))          # start just after the key and its [
      if (line ~ /\]/) { sub(/\].*$/, "", line); print line; next }
      print line; found=1; next
    }
    found==1 && /\]/ { sub(/\].*$/, ""); print; found=0; next }
    found==1 {print}
  ' "$2" 2>/dev/null | grep -oE '"[^"]+"' | tr -d '"'
}

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

  local repos_block folders kinds n_folders
  repos_block="$(_block '"repositories": [' "$WS")"
  if [ -z "$repos_block" ]; then
    _fail "repositories block empty or not found"
    return
  fi
  folders="$(_values_in '"folder"' "$repos_block")"
  kinds="$(_values_in '"kind"' "$repos_block")"
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
      application-code|shared-library|sql-scripts|import-config|reports|tests|docs)
        _pass "kind '$k'" ;;
      unknown)
        _warn "a repository is classified 'unknown' — classify it by hand in workspace.json" ;;
      *)
        _fail "kind '$k' not allowed (application-code shared-library sql-scripts import-config reports tests docs unknown)" ;;
    esac
  done <<< "$kinds"

  # every top-level folder in the codebase root should be declared
  local d name
  for d in "$CODEBASE"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    _in_list "$name" "$folders" && continue
    _warn "folder '$name' is in the codebase root but not declared in workspace.json"
  done

  # every recorded cross-reference path must exist on disk
  local xr_block p n_bad
  xr_block="$(awk '/"cross_references": \{/{f=1} f{print}' "$WS")"
  n_bad=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ ! -e "$CODEBASE/$p" ]; then
      _fail "cross-reference path missing: $p"
      n_bad=$((n_bad+1))
    fi
  done <<< "$(printf "%s\n" "$xr_block" \
      | grep -oE '"(definition|defined_in|workflow|at|file|via_file)"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | sed -E 's/^[^:]*:[[:space:]]*"//; s/"$//' | sort -u)"
  [ "$n_bad" -eq 0 ] && _pass "all cross-reference paths exist on disk"

  # counts, for the report
  local n_proc n_tab n_view n_syn n_con n_api n_msg n_imp n_unres n_ren
  n_proc="$(printf "%s\n" "$(_block '"procedures": [' "$WS")" | grep -c '"definition"' || true)"
  n_tab="$(printf "%s\n"  "$(_block '"tables": ['     "$WS")" | grep -c '"definition"' || true)"
  n_view="$(printf "%s\n" "$(_block '"views": ['      "$WS")" | grep -c '"definition"' || true)"
  n_syn="$(printf "%s\n"  "$(_block '"synonyms": ['   "$WS")" | grep -c '"target"'     || true)"
  n_con="$(printf "%s\n"  "$(_block '"contracts": ['  "$WS")" | grep -c '"kind"'       || true)"
  n_api="$(printf "%s\n"  "$(_block '"apis": ['       "$WS")" | grep -c '"defined_in"' || true)"
  n_msg="$(printf "%s\n"  "$(_block '"messaging": ['  "$WS")" | grep -c '"topic"'      || true)"
  n_imp="$(printf "%s\n"  "$(_block '"imports": ['    "$WS")" | grep -c '"workflow"'   || true)"
  n_unres="$(printf "%s\n" "$(_block '"unresolvable": [' "$WS")" | grep -c '"why"'     || true)"
  n_ren="$(grep -c '"from"' "$WS" || true)"
  _out ""
  _out "  cross-references: $n_proc procedures, $n_tab tables, $n_view views, $n_syn synonyms,"
  _out "                    $n_api API routes, $n_msg topics, $n_imp imports, $n_con contracts"
  _out "  column/field renames recorded: $n_ren"
  _out ""
  [ "$n_unres" -gt 0 ] && _warn "$n_unres unresolvable references — a person should read those call sites"

  if [ -f "$FOLDER/workspace-map.md" ]; then
    _pass "workspace-map.md present"
  else
    _fail "workspace-map.md missing"
  fi
}

# ---- Gate L: source-map.json after the link pass ---------------------------

gate_link() {
  _out ""
  _out "Gate L — source-map.json (cross-references injected):"
  _out ""

  if [ ! -f "$WS" ]; then
    _fail "workspace.json missing — cannot validate the link pass without it"
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

  if [ -f "$FOLDER/source-map.pre-link.json" ]; then
    _pass "backup source-map.pre-link.json present"
  else
    _fail "source-map.pre-link.json missing — the link pass must back up before writing"
  fi
  if [ -f "$FOLDER/source-map-links.md" ]; then
    _pass "source-map-links.md present"
  else
    _fail "source-map-links.md missing — the link pass has not run"
  fi

  local live
  live="$(_values_in '"folder"' "$(_block '"repositories": [' "$WS")")"

  # every path in the map must exist and sit inside a declared repository
  local p top n_bad
  n_bad=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    top="${p%%/*}"
    if grep -A2 -F "\"path\": \"$p\"" "$SM" | grep -q '"snippet": "UNRESOLVABLE'; then
      continue
    fi
    if [ ! -e "$CODEBASE/$p" ]; then
      _fail "path does not exist: $p"; n_bad=$((n_bad+1)); continue
    fi
    if ! _in_list "$top" "$live"; then
      _fail "path is not inside a declared repository ($top): $p"; n_bad=$((n_bad+1)); continue
    fi
  done <<< "$(_values '"path"' "$SM" | sort -u)"
  [ "$n_bad" -eq 0 ] && _pass "all paths exist and sit inside declared repositories"

  # workflow_configs entries must exist too (plain strings, not path keys)
  local wf_bad
  wf_bad=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ ! -e "$CODEBASE/$p" ]; then
      _fail "workflow_configs entry does not exist: $p"; wf_bad=$((wf_bad+1))
    fi
  done <<< "$(_array_items '"workflow_configs": [' "$SM" | sort -u)"
  [ "$wf_bad" -eq 0 ] && _pass "workflow_configs entries exist"

  # a procedure the map names must have its definition linked
  local proc_block name def
  proc_block="$(_block '"procedures": [' "$WS")"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    def="$(printf "%s\n" "$proc_block" | grep -A1 -F "\"name\": \"$name\"" \
          | grep -oE '"definition"[[:space:]]*:[[:space:]]*"[^"]*"' \
          | sed -E 's/^[^:]*:[[:space:]]*"//; s/"$//' | head -1)"
    [ -n "$def" ] || continue
    if _has "$name" "$SM"; then
      if _has "\"path\": \"$def\"" "$SM"; then
        _pass "procedure $name — definition linked"
      else
        _fail "procedure $name is referenced but its definition is not linked: $def"
      fi
    fi
  done <<< "$(_values_in '"name"' "$proc_block")"

  # a table the map references must have its DDL linked
  local tbl_block
  tbl_block="$(_block '"tables": [' "$WS")"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    def="$(printf "%s\n" "$tbl_block" | grep -A1 -F "\"name\": \"$name\"" \
          | grep -oE '"definition"[[:space:]]*:[[:space:]]*"[^"]*"' \
          | sed -E 's/^[^:]*:[[:space:]]*"//; s/"$//' | head -1)"
    [ -n "$def" ] || continue
    if _has "\"$name\"" "$SM"; then
      if _has "\"path\": \"$def\"" "$SM"; then
        _pass "table $name — DDL linked"
      else
        _fail "table $name is referenced but its DDL is not linked: $def"
      fi
    fi
  done <<< "$(_values_in '"name"' "$tbl_block")"

  # a view the map references must have its definition linked
  local view_block
  view_block="$(_block '"views": [' "$WS")"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    def="$(printf "%s\n" "$view_block" | grep -A1 -F "\"name\": \"$name\"" \
          | grep -oE '"definition"[[:space:]]*:[[:space:]]*"[^"]*"' \
          | sed -E 's/^[^:]*:[[:space:]]*"//; s/"$//' | head -1)"
    [ -n "$def" ] || continue
    if _has "\"$name\"" "$SM"; then
      if _has "\"path\": \"$def\"" "$SM"; then
        _pass "view $name — definition linked"
      else
        _fail "view $name is referenced but its definition is not linked: $def"
      fi
    fi
  done <<< "$(_values_in '"name"' "$view_block")"

  # API and message hops that were injected
  local n_api_hop n_msg_hop
  n_api_hop="$(grep -c 'API hop:' "$SM" 2>/dev/null || true)"
  n_msg_hop="$(grep -c 'message hop:' "$SM" 2>/dev/null || true)"
  _out ""
  local n_ren_note
  n_ren_note="$(grep -cE 'COLUMN RENAME|FIELD RENAME' "$SM" 2>/dev/null || true)"
  _out "  injected hops: $n_api_hop API, $n_msg_hop messaging; rename notes: $n_ren_note"
  _out ""
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
  map)  gate_map ;;
  link) gate_link ;;
  all)
    gate_map
    gate_link
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
