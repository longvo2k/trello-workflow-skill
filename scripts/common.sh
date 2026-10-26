#!/usr/bin/env bash
# Shared helpers for the trello-workflow scripts.
# Secrets come from the environment (for example via direnv).
# Per-project settings come from .trello-workspace.json (no secrets in it).

set -euo pipefail

# Shells that don't run the direnv hook (scripts, agents, CI) still get the project's .envrc:
# re-run this script once through `direnv exec` when the current folder has an allowed .envrc.
if [[ -z "${WORKFLOW_DIRENV_LOADED:-}" ]] && command -v direnv >/dev/null 2>&1 \
  && [[ "$(direnv status 2>/dev/null)" == *$'\nFound RC allowed 0'* ]]; then
  export WORKFLOW_DIRENV_LOADED=1
  exec direnv exec "$PWD" bash "$0" "$@"
fi

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_NAME=".trello-workspace.json"
WS_FILE="${WS_FILE:-}"

die() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is not installed. $2"; }

need jq "Install it with: brew install jq"

# Find .trello-workspace.json in the current folder or a parent folder.
# TRELLO_WORKSPACE_FILE overrides the search.
find_workspace() {
  if [[ -n "${TRELLO_WORKSPACE_FILE:-}" ]]; then
    [[ -f "$TRELLO_WORKSPACE_FILE" ]] || { echo "error: TRELLO_WORKSPACE_FILE points to a missing file: $TRELLO_WORKSPACE_FILE" >&2; return 1; }
    echo "$TRELLO_WORKSPACE_FILE"
    return
  fi
  local dir="$PWD"
  while :; do
    if [[ -f "$dir/$WORKSPACE_NAME" ]]; then echo "$dir/$WORKSPACE_NAME"; return; fi
    [[ "$dir" == "/" ]] && break
    dir="$(dirname "$dir")"
  done
  echo "error: no $WORKSPACE_NAME in $PWD or any parent folder." >&2
  echo "Create one with: $SKILL_DIR/scripts/workspace.sh init" >&2
  return 1
}

load_workspace() {
  [[ -n "$WS_FILE" ]] && return
  WS_FILE="$(find_workspace)" || exit 1
  jq empty "$WS_FILE" 2>/dev/null || die "$WS_FILE is not valid JSON"
}

# ws_get '.trello.board' -> value or empty string
ws_get() { jq -r "$1 // empty" "$WS_FILE"; }

urlencode() { jq -rn --arg v "$1" '$v | @uri'; }

# ---------- Trello ----------

TRELLO_API="${TRELLO_API_URL:-https://api.trello.com/1}"

require_trello_env() {
  [[ -n "${TRELLO_API_KEY:-}" ]] || die "TRELLO_API_KEY is not set. Add it to your .envrc and run: direnv allow"
  [[ -n "${TRELLO_API_TOKEN:-}" ]] || die "TRELLO_API_TOKEN is not set. Add it to your .envrc and run: direnv allow"
}

# trello_api METHOD /path [curl args...]
# Key and token go in an Authorization header through a curl config on a file descriptor,
# so they never appear in URLs, logs or `ps`.
trello_api() {
  require_trello_env
  local method="$1" path="$2"; shift 2
  local authcfg out
  authcfg="$(printf 'header = "Authorization: OAuth oauth_consumer_key=\\"%s\\", oauth_token=\\"%s\\""\n' "$TRELLO_API_KEY" "$TRELLO_API_TOKEN")"
  # On an HTTP error the body goes to stderr, so callers never mistake it for data.
  if ! out="$(curl -sS -L --fail-with-body -X "$method" -K <(echo "$authcfg") \
    -H "Accept: application/json" "$TRELLO_API$path" "$@" 2>&1)"; then
    echo "$out" >&2
    return 1
  fi
  [[ -z "$out" ]] || printf '%s\n' "$out"
}

# Board short link from .trello.board (accepts a board URL or short link).
board_id() {
  local b; b="$(ws_get .trello.board)"
  [[ -n "$b" ]] || die "trello.board is missing in $WS_FILE"
  if [[ "$b" =~ trello\.com/b/([A-Za-z0-9]+) ]]; then b="${BASH_REMATCH[1]}"; fi
  echo "$b"
}

# Card reference -> something /cards/{x} accepts.
# Accepts a card URL, a short link (8 chars), a card id, or a card number on the board (#123 or 123).
resolve_card() {
  local ref="$1"
  if [[ "$ref" =~ trello\.com/c/([A-Za-z0-9]+) ]]; then echo "${BASH_REMATCH[1]}"; return; fi
  if [[ "$ref" =~ ^#?([0-9]+)$ ]]; then
    local n="${BASH_REMATCH[1]}" id
    id="$(trello_api GET "/boards/$(board_id)/cards/all?fields=idShort,shortLink" \
      | jq -r --argjson n "$n" '[.[] | select(.idShort == $n)][0].shortLink // empty')" || return 1
    [[ -n "$id" ]] || die "no card #$n on board $(board_id)"
    echo "$id"; return
  fi
  if [[ "$ref" =~ ^[A-Za-z0-9]{8}$ || "$ref" =~ ^[0-9a-f]{24}$ ]]; then echo "$ref"; return; fi
  die "not a card reference: $ref (use a card URL, short link, or card number like #123)"
}

# List name (or a key from .trello.lists, e.g. "doing") -> list id on the board.
resolve_list() {
  local name="$1" mapped lists id
  mapped="$(jq -r --arg k "$name" '.trello.lists[$k] // empty' "$WS_FILE")"
  [[ -n "$mapped" ]] && name="$mapped"
  lists="$(trello_api GET "/boards/$(board_id)/lists?filter=open&fields=name")" || return 1
  id="$(jq -r --arg n "$name" '[.[] | select((.name | ascii_downcase) == ($n | ascii_downcase))][0].id // empty' <<<"$lists")"
  [[ -n "$id" ]] || die "no list \"$name\" on the board. Lists: $(jq -r '[.[].name] | join(", ")' <<<"$lists")"
  echo "$id"
}

resolve_label() {
  local name="$1" labels id
  labels="$(trello_api GET "/boards/$(board_id)/labels?fields=name,color&limit=1000")" || return 1
  id="$(jq -r --arg n "$name" '[.[] | select(((.name // "") | ascii_downcase) == ($n | ascii_downcase) or .color == $n)][0].id // empty' <<<"$labels")"
  [[ -n "$id" ]] || die "no label \"$name\". Labels: $(jq -r '[.[] | (if (.name // "") != "" then .name else .color end)] | join(", ")' <<<"$labels")"
  echo "$id"
}

# "me", a username, or a full name -> member id.
resolve_member() {
  local who="$1" members id
  if [[ "$who" == me ]]; then trello_api GET "/members/me?fields=id" | jq -r .id; return; fi
  members="$(trello_api GET "/boards/$(board_id)/members?fields=fullName,username")" || return 1
  id="$(jq -r --arg w "${who#@}" '[.[] | select((.username | ascii_downcase) == ($w | ascii_downcase) or (.fullName | ascii_downcase) == ($w | ascii_downcase))][0].id // empty' <<<"$members")"
  [[ -n "$id" ]] || die "no board member \"$who\". Members: $(jq -r '[.[] | "\(.fullName) (@\(.username))"] | join(", ")' <<<"$members")"
  echo "$id"
}

# ---------- Bitbucket Cloud ----------

BB_API="${BITBUCKET_API_URL:-https://api.bitbucket.org/2.0}"

bb_workspace() {
  local w; w="$(ws_get .bitbucket.workspace)"
  [[ -n "$w" ]] || die "bitbucket.workspace is missing in $WS_FILE"
  echo "$w"
}
bb_default_repo() { local r; r="$(ws_get .bitbucket.defaultRepo)"; [[ -n "$r" ]] || r="$(ws_get '.bitbucket.repos[0]')"; echo "$r"; }
bb_repos() { jq -r '.bitbucket.repos // [] | .[]' "$WS_FILE"; }

bb_authcfg() {
  if [[ -n "${BITBUCKET_ACCESS_TOKEN:-}" ]]; then
    printf 'header = "Authorization: Bearer %s"\n' "$BITBUCKET_ACCESS_TOKEN"
  elif [[ -n "${BITBUCKET_API_TOKEN:-}" ]]; then
    local user="${BITBUCKET_EMAIL:-${BITBUCKET_USERNAME:-}}"
    [[ -n "$user" ]] || die "BITBUCKET_EMAIL is not set (needed with BITBUCKET_API_TOKEN)"
    printf 'user = "%s:%s"\n' "$user" "$BITBUCKET_API_TOKEN"
  else
    die "No Bitbucket token. Set BITBUCKET_EMAIL + BITBUCKET_API_TOKEN, or BITBUCKET_ACCESS_TOKEN, in your .envrc"
  fi
}

# bb_get /repositories/... [curl args...]  (path is relative to the 2.0 API, or a full URL)
# The token goes through a curl config on a file descriptor, so it never shows in `ps`.
bb_get() {
  local path="$1"; shift
  local url="$path"
  [[ "$url" == http* ]] || url="$BB_API$path"
  local authcfg; authcfg="$(bb_authcfg)" || return 1
  # On an HTTP error the body goes to stderr, so callers never mistake it for data.
  local out
  if ! out="$(curl -sS -L --fail-with-body -K <(echo "$authcfg") "$url" "$@" 2>&1)"; then
    echo "$out" >&2
    return 1
  fi
  printf '%s\n' "$out"
}
