#!/usr/bin/env bash
# Read-only Bitbucket Cloud helper. Repo defaults to bitbucket.defaultRepo; pick another with -r SLUG.
#
#   bitbucket.sh whoami                     Who the token belongs to
#   bitbucket.sh repos [--all]              Repos in the workspace config (--all: whole Bitbucket workspace)
#   bitbucket.sh find TEXT                  Branches and PRs mentioning TEXT (card number or short link), across configured repos
#   bitbucket.sh branches [TEXT]            Branches, newest first, optionally matching TEXT
#   bitbucket.sh prs [STATE] [TEXT]         PRs (STATE: OPEN default, MERGED, DECLINED, ALL)
#   bitbucket.sh pr ID                      PR details, reviewers and approvals
#   bitbucket.sh pr-diff ID                 Full PR diff
#   bitbucket.sh pr-diffstat ID             Files changed in a PR
#   bitbucket.sh pr-comments ID             PR comments, including inline ones
#   bitbucket.sh commits [BRANCH] [N]       Recent commits (default: main branch, 20)
#   bitbucket.sh pipelines [N]              Recent pipeline runs (default 10)
#   bitbucket.sh file PATH [REF]            File contents at REF (default: main branch)
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

load_workspace

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 1; }

repo=""
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--repo) repo="${2:?repo slug required after $1}"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
if [[ ${#args[@]} -gt 0 ]]; then set -- "${args[@]}"; else set --; fi

cmd="${1:-}"; [[ -n "$cmd" ]] || usage; shift

ws="$(bb_workspace)"
repo="${repo:-$(bb_default_repo)}"
need_repo() { [[ -n "$repo" ]] || die "no repo. Pass -r SLUG or set bitbucket.defaultRepo in $WS_FILE"; }
rpath() { need_repo; echo "/repositories/$ws/$repo"; }
main_branch() { bb_get "$(rpath)" | jq -r '.mainbranch.name // "main"'; }
pr_states() {
  local s; s="$(echo "$1" | tr '[:lower:]' '[:upper:]')"
  case "$s" in
    ALL) echo "state=OPEN&state=MERGED&state=DECLINED&state=SUPERSEDED" ;;
    OPEN|MERGED|DECLINED|SUPERSEDED) echo "state=$s" ;;
    *) die "unknown PR state: $1" ;;
  esac
}
pr_list_fmt='.values[] | "#\(.id) [\(.state)] \(.title)\n    \(.source.branch.name) -> \(.destination.branch.name) | \(.author.display_name) | updated \(.updated_on[0:10]) | \(.links.html.href)"'

case "$cmd" in
  whoami)
    bb_get /user | jq -r '"\(.display_name) (\(.nickname // .username // "-")) id=\(.account_id // "-")"'
    ;;

  repos)
    if [[ "${1:-}" == "--all" ]]; then
      bb_get "/repositories/$ws?pagelen=100&sort=-updated_on" \
        | jq -r '.values[] | "\(.slug)  main=\(.mainbranch.name // "-")  updated \(.updated_on[0:10])"'
    else
      echo "Workspace: $ws"
      echo "Default repo: ${repo:-"(none)"}"
      bb_repos | sed 's/^/- /'
    fi
    ;;

  find)
    key="${1:?issue key required}"
    list="$(bb_repos)"; [[ -n "$list" ]] || list="$repo"
    [[ -n "$list" ]] || die "no repos in $WS_FILE"
    for r in $list; do
      echo "== $r"
      q="$(urlencode "name ~ \"$key\"")"
      bb_get "/repositories/$ws/$r/refs/branches?q=$q&sort=-target.date&pagelen=20" \
        | jq -r '.values | if length == 0 then "  branches: (none)" else (.[] | "  branch \(.name)  \(.target.date[0:10])  \(.target.hash[0:8])") end'
      q="$(urlencode "title ~ \"$key\" OR source.branch.name ~ \"$key\" OR description ~ \"$key\"")"
      bb_get "/repositories/$ws/$r/pullrequests?$(pr_states ALL)&q=$q&pagelen=20" \
        | jq -r '.values | if length == 0 then "  PRs: (none)" else (.[] | "  PR #\(.id) [\(.state)] \(.title)  \(.source.branch.name) -> \(.destination.branch.name)  \(.links.html.href)") end'
    done
    ;;

  branches)
    url="$(rpath)/refs/branches?sort=-target.date&pagelen=30"
    [[ -n "${1:-}" ]] && url+="&q=$(urlencode "name ~ \"$1\"")"
    bb_get "$url" | jq -r '.values[] | "\(.name)  \(.target.date[0:10])  \(.target.author.raw // "-")  \(.target.hash[0:8])"'
    ;;

  prs)
    state="${1:-OPEN}"
    url="$(rpath)/pullrequests?$(pr_states "$state")&pagelen=30"
    [[ -n "${2:-}" ]] && url+="&q=$(urlencode "title ~ \"$2\" OR source.branch.name ~ \"$2\"")"
    bb_get "$url" | jq -r "if (.values | length) == 0 then \"(no pull requests)\" else ($pr_list_fmt) end"
    ;;

  pr)
    id="${1:?PR id required}"
    bb_get "$(rpath)/pullrequests/$id" | jq -r '
      "#\(.id) [\(.state)] \(.title)",
      "\(.source.branch.name) -> \(.destination.branch.name) | by \(.author.display_name) | created \(.created_on[0:10]) | updated \(.updated_on[0:10])",
      "Comments: \(.comment_count) | Open tasks: \(.task_count)",
      "Reviewers: \((.participants // []) | map("\(.user.display_name)\(if .approved then " (approved)" elif .state == "changes_requested" then " (changes requested)" else "" end)") | join(", ") | if . == "" then "-" else . end)",
      "Link: \(.links.html.href)",
      "",
      (.description // "(no description)")'
    ;;

  pr-diff)
    id="${1:?PR id required}"
    bb_get "$(rpath)/pullrequests/$id/diff"
    ;;

  pr-diffstat)
    id="${1:?PR id required}"
    bb_get "$(rpath)/pullrequests/$id/diffstat?pagelen=100" \
      | jq -r '.values[] | "\(.status)  +\(.lines_added) -\(.lines_removed)  \(.new.path // .old.path)"'
    ;;

  pr-comments)
    id="${1:?PR id required}"
    bb_get "$(rpath)/pullrequests/$id/comments?pagelen=100" | jq -r '
      [.values[] | select(.deleted | not)] | if length == 0 then "(no comments)" else (.[] |
      "--- \(.user.display_name) at \(.created_on[0:16])\(if .inline then " on \(.inline.path):\(.inline.to // .inline.from)" else "" end)\(if .parent then " (reply)" else "" end)\n\(.content.raw)") end'
    ;;

  commits)
    branch="${1:-$(main_branch)}"; n="${2:-20}"
    bb_get "$(rpath)/commits/$(urlencode "$branch")?pagelen=$n" \
      | jq -r '.values[] | "\(.hash[0:8])  \(.date[0:16])  \(.author.raw)  \(.message | split("\n")[0])"'
    ;;

  pipelines)
    n="${1:-10}"
    bb_get "$(rpath)/pipelines/?sort=-created_on&pagelen=$n" | jq -r '
      .values[] | "#\(.build_number)  \(.state.name)\(if .state.result then "/" + .state.result.name else "" end)  \(.target.ref_name // "-")  \(.created_on[0:16])"'
    ;;

  file)
    path="${1:?file path required}"; ref="${2:-$(main_branch)}"
    bb_get "$(rpath)/src/$(urlencode "$ref")/$path"
    ;;

  *) usage ;;
esac
