#!/usr/bin/env bash
# Workspace setup and checks.
#
#   workspace.sh init     Create .trello-workspace.json (and .envrc if missing) in the current folder
#   workspace.sh show     Show the active workspace settings and which secrets are set
#   workspace.sh doctor   Check tools, secrets, the board, and Bitbucket access
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 1; }
cmd="${1:-}"; [[ -n "$cmd" ]] || usage; shift

set_or_missing() { if [[ -n "${!1:-}" ]]; then echo "set"; else echo "missing"; fi; }

case "$cmd" in
  init)
    if [[ -f "$WORKSPACE_NAME" ]]; then
      echo "$WORKSPACE_NAME already exists here."
    else
      cp "$SKILL_DIR/templates/trello-workspace.json" "$WORKSPACE_NAME"
      echo "Created $PWD/$WORKSPACE_NAME - fill in your board and Bitbucket details."
    fi
    if [[ -f .envrc ]]; then
      echo ".envrc already exists. Make sure it exports the variables in $SKILL_DIR/templates/envrc.example"
    else
      cp "$SKILL_DIR/templates/envrc.example" .envrc
      echo "Created $PWD/.envrc - add your key and token, then run: direnv allow"
    fi
    if [[ -d .git ]] && ! git check-ignore -q .envrc 2>/dev/null; then
      warn ".envrc is not ignored by git. Add it to .gitignore so your tokens are never committed."
    fi
    ;;

  show)
    load_workspace
    echo "Workspace file: $WS_FILE"
    jq . "$WS_FILE"
    echo
    echo "Secrets (values hidden):"
    for v in TRELLO_API_KEY TRELLO_API_TOKEN BITBUCKET_EMAIL BITBUCKET_API_TOKEN BITBUCKET_ACCESS_TOKEN; do
      printf '  %-24s %s\n' "$v" "$(set_or_missing "$v")"
    done
    ;;

  doctor)
    ok=0
    pass() { echo "  ok    $*"; }
    fail() { echo "  FAIL  $*"; ok=1; }
    echo "Tools"
    for t in jq curl; do command -v "$t" >/dev/null && pass "$t" || fail "$t not installed"; done
    command -v direnv >/dev/null && pass "direnv" || echo "  info  direnv not installed (optional, but recommended for tokens)"
    echo "Workspace"
    if WS_FILE="$(find_workspace 2>/dev/null)" && jq empty "$WS_FILE" 2>/dev/null; then
      pass "$WS_FILE"
      [[ -n "$(ws_get .trello.board)" ]] && pass ".trello.board = $(ws_get .trello.board)" || fail ".trello.board is missing (run: trello.sh boards)"
      [[ -n "$(ws_get .bitbucket.workspace)" ]] && pass ".bitbucket.workspace = $(ws_get .bitbucket.workspace)" \
        || echo "  info  no bitbucket.workspace (Bitbucket commands disabled)"
    else
      fail "no valid $WORKSPACE_NAME found (run: workspace.sh init)"
      exit 1
    fi
    echo "Secrets"
    [[ -n "${TRELLO_API_KEY:-}" ]] && pass "TRELLO_API_KEY set" || fail "TRELLO_API_KEY missing"
    [[ -n "${TRELLO_API_TOKEN:-}" ]] && pass "TRELLO_API_TOKEN set" || fail "TRELLO_API_TOKEN missing"
    echo "Trello"
    if me="$( (trello_api GET "/members/me?fields=fullName,username" | jq -r '"\(.fullName) (@\(.username))"') 2>&1)"; then
      pass "token works - signed in as $me"
      if [[ -n "$(ws_get .trello.board)" ]]; then
        if b="$( (trello_api GET "/boards/$(board_id)?fields=name" | jq -r .name) 2>&1)"; then
          pass "board $(board_id) ($b)"
          lists="$(trello_api GET "/boards/$(board_id)/lists?filter=open&fields=name" | jq -r '.[].name')"
          while IFS=$'\t' read -r key name; do
            [[ -n "$key" ]] || continue
            grep -Fxiq "$name" <<<"$lists" && pass "list $key = \"$name\"" || fail "list $key = \"$name\" is not on the board"
          done < <(jq -r '.trello.lists // {} | to_entries[] | [.key, .value] | @tsv' "$WS_FILE")
          cfname="$(ws_get .worklog.customField)"
          if [[ -n "$cfname" ]]; then
            trello_api GET "/boards/$(board_id)/customFields" | jq -e --arg n "$cfname" 'any(.[]; .name == $n and .type == "number")' >/dev/null \
              && pass "custom field \"$cfname\" (number)" || fail "no number custom field \"$cfname\" on the board"
          fi
        else
          fail "cannot open board $(board_id): $(echo "$b" | head -2)"
        fi
      fi
    else
      fail "Trello rejected the request: $(echo "$me" | head -3)"
    fi
    if [[ -n "$(ws_get .bitbucket.workspace)" ]]; then
      echo "Bitbucket"
      bbws="$(ws_get .bitbucket.workspace)"
      for r in $(bb_repos); do
        if out="$( (bb_get "/repositories/$bbws/$r") 2>&1)" && name="$(jq -re '.full_name' <<<"$out" 2>/dev/null)"; then
          pass "repo $name"
        else
          fail "cannot read repo $bbws/$r: $(echo "$out" | head -2)"
        fi
      done
    fi
    exit $ok
    ;;

  *) usage ;;
esac
