#!/usr/bin/env bash
#
# pr-review.sh — fetch a pull request for review, and post a review back as
# line-anchored comments.
#
#   pr-review.sh fetch --pr <N> [--config <file>] [--host H] [--repo O/R]
#                      [--no-diff] [--max-diff-lines N]
#
#   pr-review.sh post  --pr <N> --comments <file> [--config <file>]
#                      [--event COMMENT|APPROVE|REQUEST_CHANGES]
#                      [--body <text> | --body-file <file>]
#                      [--commit-id <sha>] [--no-verify-paths] [--dry-run]
#
# config.json only has to name the host and repo. Diff limits, path exclusions
# and review conventions are optional overrides of the defaults below.
# Command-line flags win over the config; the config wins over the defaults.
#
# `post` writes to GitHub. Run it with --dry-run first and show the payload.

set -euo pipefail

readonly EXIT_USAGE=1
readonly EXIT_DEPENDENCY=2
readonly EXIT_AUTH=3
readonly EXIT_NOT_FOUND=4
readonly EXIT_INPUT=5
readonly EXIT_API=6

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_HOST="github.com"  # (change it to org host name here)
DEFAULT_MAX_DIFF_LINES=800
DEFAULT_EVENT="COMMENT"

# Generated, vendored and binary files, skipped unless fetch.excludePaths
# overrides this list in the config.
DEFAULT_EXCLUDE_PATTERNS=(
  "*.lock"
  "package-lock.json"
  "yarn.lock"
  "pnpm-lock.yaml"
  "poetry.lock"
  "Cargo.lock"
  "go.sum"
  "composer.lock"
  "Gemfile.lock"
  "*.min.js"
  "*.min.css"
  "*.map"
  "*.snap"
  "*.svg"
  "*.png"
  "*.jpg"
  "*.pdf"
  "dist/*"
  "build/*"
  "vendor/*"
  "node_modules/*"
  "*/generated/*"
  "*.pb.go"
  "*_pb2.py"
)

COMMAND=""
CONFIG_PATH=""
PR_NUMBER=""
HOST=""
REPO=""
MAX_DIFF_LINES=""
INCLUDE_DIFF=""
COMMENTS_FILE=""
EVENT=""
BODY=""
BODY_FILE=""
COMMIT_ID=""
VERIFY_PATHS=true
ANNOTATE=true
DRY_RUN=false

CONFIG_FILE=""
EFFECTIVE_CONFIG=""
PROFILE=""
EXCLUDE_PATTERNS=()

log() { printf '[INFO] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }

die() {
  local code="$1" tag="$2" message="$3"
  printf '%s: %s\n' "$tag" "$message" >&2
  exit "$code"
}

usage() {
  cat <<'EOF'
Usage:
  pr-review.sh fetch --pr <NUMBER> [options]
  pr-review.sh post  --pr <NUMBER> --comments <FILE> [options]

Common options:
  --config <FILE>          config.json to use (default: alongside this script)
  --profile <NAME>         apply a named profile from the config's "profiles" block
  --host <HOST>            GitHub host; defaults to github.host from the config
  --repo <OWNER/REPO>      target repository; a clone URL or web link also works
  -h, --help               show this message

  --pr accepts 7, #7, or a full pull request URL. A URL supplies the host and
  repository too, so --host and --repo become unnecessary.

fetch options:
  --no-diff                metadata only, skip the unified diff
  --no-annotate            emit a plain unified diff instead of a line-numbered one
  --max-diff-lines <N>     truncate the diff at N lines (0 = unlimited)

post options:
  --comments <FILE>        JSON array of line-anchored comments
  --event <EVENT>          COMMENT (default), APPROVE or REQUEST_CHANGES
  --body <TEXT>            review summary shown above the inline comments
  --body-file <FILE>       read the summary from a file instead
  --commit-id <SHA>        default: current head commit of the PR
  --no-verify-paths        skip checking comment paths and lines against the diff
  --dry-run                print the payload without posting

Comment entry format:
  { "path": "src/app.ts", "line": 42, "side": "RIGHT", "body": "..." }
  Optional: "start_line" and "start_side" for a multi-line range.

Exit codes:
  1 usage   2 missing dependency   3 auth   4 not found   5 bad input   6 API error
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
  if [[ $# -eq 0 ]]; then
    usage
    exit "$EXIT_USAGE"
  fi

  case "$1" in
    fetch | post)
      COMMAND="$1"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      die "$EXIT_USAGE" "UNKNOWN_COMMAND" "'$1' is not a command. Expected 'fetch' or 'post'."
      ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pr | -p) PR_NUMBER="${2:-}"; shift 2 ;;
      --config) CONFIG_PATH="${2:-}"; shift 2 ;;
      --profile) PROFILE="${2:-}"; shift 2 ;;
      --host) HOST="${2:-}"; shift 2 ;;
      --repo | -r) REPO="${2:-}"; shift 2 ;;
      --no-diff) INCLUDE_DIFF=false; shift ;;
      --no-annotate) ANNOTATE=false; shift ;;
      --max-diff-lines) MAX_DIFF_LINES="${2:-}"; shift 2 ;;
      --comments | --comments-file) COMMENTS_FILE="${2:-}"; shift 2 ;;
      --event) EVENT="${2:-}"; shift 2 ;;
      --body) BODY="${2:-}"; shift 2 ;;
      --body-file) BODY_FILE="${2:-}"; shift 2 ;;
      --commit-id) COMMIT_ID="${2:-}"; shift 2 ;;
      --no-verify-paths) VERIFY_PATHS=false; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      -h | --help) usage; exit 0 ;;
      *)
        usage
        die "$EXIT_USAGE" "UNKNOWN_ARGUMENT" "'$1' is not a recognised option."
        ;;
    esac
  done
}

split_repo_url() {
  local url="$1" rest host_part path_part
  rest="${url#*://}"
  host_part="${rest%%/*}"
  path_part="${rest#*/}"
  path_part="${path_part%.git}"

  [[ "$path_part" =~ ^([^/]+)/([^/]+) ]] || return 1
  printf '%s\n%s/%s\n' "$host_part" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

normalize_targets() {
  local parsed

  if [[ "$PR_NUMBER" == *://* ]]; then
    local url="${PR_NUMBER%%\?*}"
    url="${url%%#*}"
    local path_part="${url#*://}"
    path_part="${path_part#*/}"

    [[ "$path_part" =~ ^([^/]+)/([^/]+)/pulls?/([0-9]+) ]] ||
      die "$EXIT_INPUT" "INVALID_PR_URL" "'$PR_NUMBER' is not a pull request URL."

    [[ -z "$HOST" ]] && HOST="$(printf '%s' "${url#*://}" | cut -d/ -f1)"
    [[ -z "$REPO" ]] && REPO="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    PR_NUMBER="${BASH_REMATCH[3]}"
  else
    PR_NUMBER="${PR_NUMBER#\#}"
  fi

  if [[ "$REPO" == *://* ]]; then
    parsed="$(split_repo_url "$REPO")" ||
      die "$EXIT_INPUT" "INVALID_REPO_URL" "'$REPO' is not a repository URL."
    [[ -z "$HOST" ]] && HOST="$(sed -n 1p <<<"$parsed")"
    REPO="$(sed -n 2p <<<"$parsed")"
  elif [[ "$REPO" =~ ^git@([^:]+):(.+)$ ]]; then
    [[ -z "$HOST" ]] && HOST="${BASH_REMATCH[1]}"
    REPO="${BASH_REMATCH[2]%.git}"
  fi
}

# ---------------------------------------------------------------------------
# Prerequisites, configuration, authentication
# ---------------------------------------------------------------------------

require_tools() {
  command -v gh >/dev/null 2>&1 ||
    die "$EXIT_DEPENDENCY" "GH_NOT_FOUND" "the GitHub CLI is not installed or not in PATH."
  command -v jq >/dev/null 2>&1 ||
    die "$EXIT_DEPENDENCY" "JQ_NOT_FOUND" "jq is not installed or not in PATH."
}

resolve_config_file() {
  if [[ -n "$CONFIG_PATH" ]]; then
    [[ -f "$CONFIG_PATH" ]] ||
      die "$EXIT_INPUT" "CONFIG_NOT_FOUND" "'$CONFIG_PATH' does not exist."
    CONFIG_FILE="$CONFIG_PATH"
    return
  fi

  if [[ -n "${PR_REVIEW_CONFIG:-}" && -f "${PR_REVIEW_CONFIG}" ]]; then
    CONFIG_FILE="$PR_REVIEW_CONFIG"
    return
  fi

  local candidate
  for candidate in "$SCRIPT_DIR/config.json" "$SCRIPT_DIR/../config.json" "./pr-review.config.json"; do
    if [[ -f "$candidate" ]]; then
      CONFIG_FILE="$candidate"
      return
    fi
  done

  CONFIG_FILE=""
}

config_value() {
  local filter="$1" fallback="$2" value
  value="$(jq -r "$filter // empty" "$EFFECTIVE_CONFIG")"
  printf '%s' "${value:-$fallback}"
}

# Layers, lowest precedence first: the committed config, the selected profile,
# then config.local.json sitting beside it. Objects merge key by key; arrays
# replace wholesale, so an overriding excludePaths list is taken as given.
# teamRulesAdd is the exception: it appends to the inherited rules instead of
# replacing them, so a team can extend the baseline without restating it.
build_effective_config() {
  local base="$TMP_DIR/base-config.json"
  local overlay="$TMP_DIR/overlay-config.json"
  local local_file=""

  EFFECTIVE_CONFIG="$TMP_DIR/effective-config.json"

  if [[ -n "$CONFIG_FILE" ]]; then
    cp "$CONFIG_FILE" "$base"
    local_file="$(dirname "$CONFIG_FILE")/config.local.json"
  else
    printf '{}' >"$base"
  fi

  if [[ -n "$local_file" && -f "$local_file" ]]; then
    jq empty "$local_file" >/dev/null 2>&1 ||
      die "$EXIT_INPUT" "INVALID_LOCAL_CONFIG" "'$local_file' is not valid JSON."
    cp "$local_file" "$overlay"
    log "Overlay: $local_file"
  else
    printf '{}' >"$overlay"
  fi

  [[ -z "$PROFILE" ]] && PROFILE="${PR_REVIEW_PROFILE:-}"
  [[ -z "$PROFILE" ]] && PROFILE="$(jq -r '.defaultProfile // empty' "$base")"

  if [[ -n "$PROFILE" ]]; then
    jq -e --arg name "$PROFILE" '.profiles[$name] != null' "$base" >/dev/null 2>&1 ||
      die "$EXIT_INPUT" "PROFILE_NOT_FOUND" "'$PROFILE' is not defined under \"profiles\" in the config."
    log "Profile: $PROFILE"
  fi

  jq -n \
    --slurpfile baseArr "$base" \
    --slurpfile overlayArr "$overlay" \
    --arg profile "$PROFILE" \
    '($baseArr[0] // {}) as $base
     | ($base | del(.profiles) | del(.defaultProfile)) as $root
     | (if $profile == "" then {} else ($base.profiles[$profile] // {}) end) as $selected
     | ($overlayArr[0] // {}) as $local
     | ($root * $selected * $local) as $merged
     | (($merged.review.teamRules // [])
        + ($selected.review.teamRulesAdd // [])
        + ($local.review.teamRulesAdd // [])) as $rules
     | $merged
     | if ($rules | length) > 0 then .review.teamRules = $rules else . end
     | del(.review.teamRulesAdd)' >"$EFFECTIVE_CONFIG"
}

load_config() {
  resolve_config_file

  if [[ -n "$CONFIG_FILE" ]]; then
    jq empty "$CONFIG_FILE" >/dev/null 2>&1 ||
      die "$EXIT_INPUT" "INVALID_CONFIG" "'$CONFIG_FILE' is not valid JSON."
    log "Config: $CONFIG_FILE"
  else
    warn "No config.json found — using built-in defaults."
  fi

  build_effective_config

  [[ -z "$HOST" ]] && HOST="$(config_value '.github.host' "$DEFAULT_HOST")"
  [[ -z "$REPO" ]] && REPO="$(config_value '.github.repo' "")"
  [[ -z "$EVENT" ]] && EVENT="$(config_value '.review.defaultEvent' "$DEFAULT_EVENT")"
  [[ -z "$MAX_DIFF_LINES" ]] && MAX_DIFF_LINES="$(config_value '.fetch.maxDiffLines' "$DEFAULT_MAX_DIFF_LINES")"
  [[ -z "$INCLUDE_DIFF" ]] && INCLUDE_DIFF="$(config_value '.fetch.includeDiff' "true")"

  if jq -e '.fetch.excludePaths | type == "array"' "$EFFECTIVE_CONFIG" >/dev/null 2>&1; then
    local pattern
    while IFS= read -r pattern; do
      [[ -n "$pattern" ]] && EXCLUDE_PATTERNS+=("$pattern")
    done < <(jq -r '.fetch.excludePaths[]' "$EFFECTIVE_CONFIG")
  else
    EXCLUDE_PATTERNS=("${DEFAULT_EXCLUDE_PATTERNS[@]}")
  fi

  [[ -n "$REPO" && "$REPO" != "OWNER/REPO" ]] ||
    die "$EXIT_INPUT" "REPO_NOT_CONFIGURED" "set github.repo in config.json or pass --repo OWNER/REPO."

  [[ "$REPO" == */* ]] ||
    die "$EXIT_INPUT" "INVALID_REPO" "'$REPO' is not in OWNER/REPO form."
}

validate_pr_number() {
  [[ -n "$PR_NUMBER" ]] ||
    die "$EXIT_USAGE" "MISSING_PR_NUMBER" "--pr is required."
  [[ "$PR_NUMBER" =~ ^[0-9]+$ ]] ||
    die "$EXIT_USAGE" "INVALID_PR_NUMBER" "'$PR_NUMBER' is not a positive integer."
}

gh_cmd() {
  GH_HOST="$HOST" gh "$@"
}

require_auth() {
  GH_HOST="$HOST" gh auth status --hostname "$HOST" >/dev/null 2>&1 ||
    die "$EXIT_AUTH" "GH_AUTH_FAILED" "not authenticated to $HOST. Run: gh auth login --hostname $HOST"
}

classify_gh_error() {
  local err="$1"
  if grep -qiE 'could not resolve|http 404|not found' <<<"$err"; then
    die "$EXIT_NOT_FOUND" "PR_NOT_FOUND" "PR #$PR_NUMBER not found in $REPO on $HOST."
  elif grep -qiE 'http 401|http 403|permission|forbidden' <<<"$err"; then
    die "$EXIT_AUTH" "GH_AUTH_ERROR" "insufficient permissions for $REPO on $HOST."
  else
    die "$EXIT_API" "GH_API_ERROR" "$err"
  fi
}

# ---------------------------------------------------------------------------
# Path exclusion
# ---------------------------------------------------------------------------

path_is_excluded() {
  local path="$1" pattern
  for pattern in ${EXCLUDE_PATTERNS[@]+"${EXCLUDE_PATTERNS[@]}"}; do
    # Unquoted on purpose: the config entries are shell glob patterns.
    # shellcheck disable=SC2053
    if [[ "$path" == $pattern || "${path##*/}" == $pattern ]]; then
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Diff shaping
#
# The annotated form carries the new-file line number on every line that has
# one, so a reviewer never has to derive it from a hunk header. Removed lines
# keep no number because they do not exist in the new file.
# ---------------------------------------------------------------------------

filter_and_annotate() {
  local raw="$1" exclude_file="$2" annotate="$3"

  awk -v exclude_file="$exclude_file" -v annotate="$annotate" '
    BEGIN { while ((getline entry < exclude_file) > 0) excluded[entry] = 1 }
    /^diff --git / {
      marker = index($0, " b/")
      current = (marker > 0) ? substr($0, marker + 3) : ""
      skip = (current in excluded)
      if (!skip) print
      next
    }
    skip { next }
    annotate != "true" { print; next }
    /^index / { next }
    /^--- / { next }
    /^\+\+\+ / { next }
    /^@@ / {
      if (match($0, /\+[0-9]+/)) lineno = substr($0, RSTART + 1, RLENGTH - 1) + 0
      print
      next
    }
    /^\\/ { next }
    {
      tag = substr($0, 1, 1)
      body = substr($0, 2)
      if (tag == "+") { printf "+%6d | %s\n", lineno, body; lineno++ }
      else if (tag == "-") { printf "-       | %s\n", body }
      else { printf " %6d | %s\n", lineno, body; lineno++ }
    }
  ' "$raw"
}

right_line_index() {
  local raw="$1" exclude_file="$2"

  awk -v exclude_file="$exclude_file" '
    BEGIN { while ((getline entry < exclude_file) > 0) excluded[entry] = 1 }
    /^diff --git / {
      marker = index($0, " b/")
      current = (marker > 0) ? substr($0, marker + 3) : ""
      skip = (current in excluded)
      next
    }
    skip { next }
    /^index / { next }
    /^--- / { next }
    /^\+\+\+ / { next }
    /^@@ / {
      if (match($0, /\+[0-9]+/)) lineno = substr($0, RSTART + 1, RLENGTH - 1) + 0
      next
    }
    /^\\/ { next }
    /^-/ { next }
    { print current "\t" lineno; lineno++ }
  ' "$raw"
}

# ---------------------------------------------------------------------------
# fetch
# ---------------------------------------------------------------------------

PR_FIELDS="number,url,title,state,isDraft,author,baseRefName,headRefName,headRefOid,createdAt,updatedAt,mergedAt,body,additions,deletions,changedFiles,files,labels,assignees,reviewRequests,statusCheckRollup,reviews"

fetch_pr_json() {
  local target="$1" err_file="$TMP_DIR/pr-view.err"
  gh_cmd pr view "$PR_NUMBER" --repo "$REPO" --json "$PR_FIELDS" \
    >"$target" 2>"$err_file" ||
    classify_gh_error "$(cat "$err_file" 2>/dev/null || true)"
}

cmd_fetch() {
  validate_pr_number
  require_auth

  log "Repo: $REPO | PR: #$PR_NUMBER | Host: $HOST"

  local pr_json="$TMP_DIR/pr.json"
  local excluded_list="$TMP_DIR/excluded.txt"
  local raw_diff="$TMP_DIR/raw.diff"
  local filtered_diff="$TMP_DIR/filtered.diff"
  local final_diff="$TMP_DIR/final.diff"

  fetch_pr_json "$pr_json"
  log "Metadata fetched"

  : >"$excluded_list"
  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] && path_is_excluded "$path" && printf '%s\n' "$path" >>"$excluded_list"
  done < <(jq -r '(.files // [])[].path' "$pr_json")

  local excluded_count
  excluded_count="$(wc -l <"$excluded_list" | tr -d '[:space:]')"
  [[ "$excluded_count" -gt 0 ]] && log "Excluding $excluded_count file(s) matched by fetch.excludePaths"

  local diff_included=false
  local diff_truncated=false
  local diff_total_lines=0
  : >"$final_diff"

  if [[ "$INCLUDE_DIFF" == "true" ]]; then
    if gh_cmd pr diff "$PR_NUMBER" --repo "$REPO" >"$raw_diff" 2>"$TMP_DIR/diff.err"; then
      filter_and_annotate "$raw_diff" "$excluded_list" "$ANNOTATE" >"$filtered_diff"

      diff_included=true
      diff_total_lines="$(wc -l <"$filtered_diff" | tr -d '[:space:]')"

      if [[ "$MAX_DIFF_LINES" -gt 0 && "$diff_total_lines" -gt "$MAX_DIFF_LINES" ]]; then
        head -n "$MAX_DIFF_LINES" "$filtered_diff" >"$final_diff"
        diff_truncated=true
        log "Diff truncated to $MAX_DIFF_LINES of $diff_total_lines reviewable lines"
      else
        cp "$filtered_diff" "$final_diff"
        log "Diff fetched — $diff_total_lines reviewable lines"
      fi
    else
      warn "Could not fetch diff: $(cat "$TMP_DIR/diff.err" 2>/dev/null || true)"
    fi
  fi

  local review_config="$TMP_DIR/review-config.json"
  jq '.review // {}' "$EFFECTIVE_CONFIG" >"$review_config"

  jq -n \
    --slurpfile prArr "$pr_json" \
    --slurpfile reviewArr "$review_config" \
    --rawfile diffText "$final_diff" \
    --rawfile excludedText "$excluded_list" \
    --argjson diffIncluded "$diff_included" \
    --argjson diffTruncated "$diff_truncated" \
    --argjson diffTotalLines "$diff_total_lines" \
    --argjson maxDiffLines "$MAX_DIFF_LINES" \
    --argjson annotated "$ANNOTATE" \
    --arg host "$HOST" \
    --arg repo "$REPO" \
    '($prArr[0]) as $pr |
     ([$excludedText | split("\n")[] | select(length > 0)]) as $excluded |
     {
       host: $host,
       repo: $repo,
       number: $pr.number,
       url: $pr.url,
       title: $pr.title,
       state: $pr.state,
       isDraft: $pr.isDraft,
       author: ($pr.author.login // "unknown"),
       baseRef: $pr.baseRefName,
       headRef: $pr.headRefName,
       headSha: $pr.headRefOid,
       createdAt: $pr.createdAt,
       updatedAt: $pr.updatedAt,
       mergedAt: ($pr.mergedAt // null),
       description: ($pr.body // ""),
       stats: {
         additions: $pr.additions,
         deletions: $pr.deletions,
         changedFiles: $pr.changedFiles
       },
       labels: [($pr.labels // [])[].name],
       assignees: [($pr.assignees // [])[] | .login],
       reviewRequestedFrom: [($pr.reviewRequests // [])[] | (.login // .name)],
       changedFiles: [
         ($pr.files // [])[] |
         {
           path: .path,
           status: (
             if .additions > 0 and .deletions == 0 then "added"
             elif .additions == 0 and .deletions > 0 then "deleted"
             else "modified"
             end
           ),
           additions: .additions,
           deletions: .deletions,
           excluded: (.path as $p | $excluded | index($p) != null)
         }
       ],
       excludedFiles: $excluded,
       checks: {
         overall: (
           ([($pr.statusCheckRollup // [])[] | (.conclusion // .state // "UNKNOWN") | ascii_upcase]) as $states |
           if ($states | length) == 0 then "NONE"
           elif ($states | any(. == "FAILURE" or . == "ERROR" or . == "TIMED_OUT")) then "FAILURE"
           elif ($states | any(. == "PENDING" or . == "IN_PROGRESS" or . == "QUEUED")) then "PENDING"
           elif ($states | all(. == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED")) then "SUCCESS"
           else "MIXED"
           end
         ),
         failing: [
           ($pr.statusCheckRollup // [])[] |
           select(((.conclusion // .state // "") | ascii_upcase) as $s |
                  $s == "FAILURE" or $s == "ERROR" or $s == "TIMED_OUT") |
           (.name // .context)
         ]
       },
       reviewSummary: {
         approved: [($pr.reviews // [])[] | select(.state == "APPROVED")] | length,
         changesRequested: [($pr.reviews // [])[] | select(.state == "CHANGES_REQUESTED")] | length,
         commented: [($pr.reviews // [])[] | select(.state == "COMMENTED")] | length
       },
       existingReviews: [
         ($pr.reviews // [])[] |
         {
           author: (.author.login // "unknown"),
           state: .state,
           body: (.body // ""),
           submittedAt: .submittedAt
         }
       ],
       reviewConfig: $reviewArr[0],
       diff: {
         included: $diffIncluded,
         truncated: $diffTruncated,
         annotated: ($diffIncluded and $annotated),
         lineNumberHint: (
           if ($diffIncluded and $annotated)
           then "Each line is prefixed with its line number in the NEW file. Use that number directly as \"line\"; lines marked - have no number and cannot be commented on with side RIGHT."
           else null
           end
         ),
         reviewableLines: $diffTotalLines,
         maxLines: $maxDiffLines,
         content: (if $diffIncluded then $diffText else null end)
       }
     }'
}

# ---------------------------------------------------------------------------
# post
# ---------------------------------------------------------------------------

validate_comments() {
  jq empty "$COMMENTS_FILE" >/dev/null 2>&1 ||
    die "$EXIT_INPUT" "INVALID_JSON" "'$COMMENTS_FILE' is not valid JSON."

  jq -e 'type == "array"' "$COMMENTS_FILE" >/dev/null 2>&1 ||
    die "$EXIT_INPUT" "INVALID_COMMENTS_FORMAT" "'$COMMENTS_FILE' must hold a top-level JSON array."

  local count
  count="$(jq 'length' "$COMMENTS_FILE")"
  [[ "$count" -gt 0 ]] ||
    die "$EXIT_INPUT" "EMPTY_COMMENTS" "'$COMMENTS_FILE' contains no comments."

  local problems
  problems="$(jq -r '
    to_entries
    | map(
        .key as $i | .value as $c
        | [
            (if ($c.path | type) != "string" or ($c.path | length) == 0
             then "entry \($i): missing or non-string \"path\"" else empty end),
            (if ($c.line | type) != "number"
             then "entry \($i): missing or non-numeric \"line\"" else empty end),
            (if ($c.body | type) != "string" or ($c.body | length) == 0
             then "entry \($i): missing or empty \"body\"" else empty end),
            (if ($c.side != null and ($c.side != "LEFT" and $c.side != "RIGHT"))
             then "entry \($i): \"side\" must be LEFT or RIGHT" else empty end),
            (if ($c.start_side != null and ($c.start_side != "LEFT" and $c.start_side != "RIGHT"))
             then "entry \($i): \"start_side\" must be LEFT or RIGHT" else empty end),
            (if ($c.start_line != null and ($c.start_line | type) != "number")
             then "entry \($i): \"start_line\" must be numeric" else empty end),
            (if ($c.start_line != null and ($c.start_line | type) == "number"
                 and ($c.line | type) == "number" and $c.start_line > $c.line)
             then "entry \($i): \"start_line\" must not be greater than \"line\"" else empty end),
            (if $c.subject_type != null
             then "entry \($i): file-level comments are not supported inside a batch review; fold that finding into --body"
             else empty end)
          ]
      )
    | flatten | .[]
  ' "$COMMENTS_FILE")"

  if [[ -n "$problems" ]]; then
    printf 'INVALID_COMMENT_ENTRY: %d problem(s) in %s — nothing was posted.\n' \
      "$(printf '%s\n' "$problems" | wc -l | tr -d '[:space:]')" "$COMMENTS_FILE" >&2
    printf '%s\n' "$problems" >&2
    exit "$EXIT_INPUT"
  fi

  log "Validated $count comment(s)"
}

verify_comments_against_diff() {
  local pr_json="$TMP_DIR/pr-paths.json"
  fetch_pr_json "$pr_json"

  local unknown
  unknown="$(jq -r --slurpfile pr "$pr_json" '
    ([$pr[0].files[]?.path]) as $changed
    | [.[] | .path] | unique
    | map(select(. as $p | $changed | index($p) == null))
    | .[]
  ' "$COMMENTS_FILE")"

  if [[ -n "$unknown" ]]; then
    printf 'INVALID_PATH: comment path(s) not among the files changed by PR #%s:\n' "$PR_NUMBER" >&2
    printf '%s\n' "$unknown" >&2
    printf 'Fix the paths, or pass --no-verify-paths to post anyway.\n' >&2
    exit "$EXIT_INPUT"
  fi

  local raw_diff="$TMP_DIR/verify.diff"
  local excluded_list="$TMP_DIR/verify-excluded.txt"
  local index_file="$TMP_DIR/right-lines.txt"

  : >"$excluded_list"
  if ! gh_cmd pr diff "$PR_NUMBER" --repo "$REPO" >"$raw_diff" 2>/dev/null; then
    warn "Could not fetch the diff to verify line numbers; posting without that check."
    return 0
  fi

  right_line_index "$raw_diff" "$excluded_list" >"$index_file"

  local offenders
  offenders="$(jq -r '.[] | select((.side // "RIGHT") == "RIGHT") | "\(.path)\t\(.line)"' "$COMMENTS_FILE" |
    while IFS= read -r entry; do
      grep -Fxq "$entry" "$index_file" || printf '%s\n' "$entry"
    done)"

  if [[ -n "$offenders" ]]; then
    printf 'INVALID_LINE: line(s) not present in the diff for this pull request:\n' >&2
    printf '%s\n' "$offenders" | sed 's/\t/ — line /' >&2
    printf 'GitHub would reject the whole review. Re-check against the annotated diff from fetch.\n' >&2
    exit "$EXIT_INPUT"
  fi

  log "Paths and line numbers verified against the diff"
}

resolve_commit_id() {
  [[ -n "$COMMIT_ID" ]] && return

  local err_file="$TMP_DIR/head.err"
  COMMIT_ID="$(gh_cmd pr view "$PR_NUMBER" --repo "$REPO" --json headRefOid --jq '.headRefOid' \
    2>"$err_file")" || classify_gh_error "$(cat "$err_file" 2>/dev/null || true)"

  [[ -n "$COMMIT_ID" ]] ||
    die "$EXIT_API" "HEAD_SHA_UNRESOLVED" "could not determine the head commit of PR #$PR_NUMBER."
}

cmd_post() {
  validate_pr_number

  [[ -n "$COMMENTS_FILE" ]] ||
    die "$EXIT_USAGE" "MISSING_COMMENTS_FILE" "--comments is required."
  [[ -f "$COMMENTS_FILE" ]] ||
    die "$EXIT_INPUT" "COMMENTS_FILE_NOT_FOUND" "'$COMMENTS_FILE' does not exist."

  case "$EVENT" in
    COMMENT | APPROVE | REQUEST_CHANGES) ;;
    *) die "$EXIT_INPUT" "INVALID_EVENT" "'$EVENT' must be COMMENT, APPROVE or REQUEST_CHANGES." ;;
  esac

  if [[ -n "$BODY_FILE" ]]; then
    [[ -f "$BODY_FILE" ]] ||
      die "$EXIT_INPUT" "BODY_FILE_NOT_FOUND" "'$BODY_FILE' does not exist."
    BODY="$(cat "$BODY_FILE")"
  fi

  require_auth
  validate_comments

  if [[ "$VERIFY_PATHS" == true ]]; then
    verify_comments_against_diff
  fi

  resolve_commit_id
  log "Head commit: $COMMIT_ID"

  local payload="$TMP_DIR/payload.json"
  jq -n \
    --slurpfile commentsArr "$COMMENTS_FILE" \
    --arg commitId "$COMMIT_ID" \
    --arg event "$EVENT" \
    --arg body "$BODY" \
    '{
       commit_id: $commitId,
       event: $event,
       body: $body,
       comments: $commentsArr[0]
     }' >"$payload"

  if [[ "$DRY_RUN" == true ]]; then
    log "Dry run — nothing was posted. Payload:"
    cat "$payload"
    return 0
  fi

  log "Posting $EVENT review to $REPO#$PR_NUMBER"

  local response="$TMP_DIR/response.json"
  local err_file="$TMP_DIR/post.err"

  if ! gh_cmd api "repos/$REPO/pulls/$PR_NUMBER/reviews" \
    --method POST --input "$payload" >"$response" 2>"$err_file"; then
    local err
    err="$(cat "$err_file" 2>/dev/null || true)"

    if grep -qiE 'http 422|must be part of the diff|pull_request_review_thread' <<<"$err"; then
      printf 'INVALID_LINE: GitHub rejected one or more comments (422).\n' >&2
      printf 'A line must appear in the diff of commit %s. Re-check line numbers against a fresh fetch.\n' "$COMMIT_ID" >&2
      printf '%s\n' "$err" >&2
      exit "$EXIT_INPUT"
    fi
    classify_gh_error "$err"
  fi

  local review_url
  review_url="$(jq -r '.html_url // empty' "$response")"
  log "Review posted"
  printf '%s\n' "$review_url"
}

# ---------------------------------------------------------------------------

main() {
  parse_args "$@"
  require_tools

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  normalize_targets
  load_config

  case "$COMMAND" in
    fetch) cmd_fetch ;;
    post) cmd_post ;;
  esac
}

main "$@"
