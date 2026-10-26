#!/usr/bin/env bash
# Trello for the project's board (.trello-workspace.json). CARD = card URL, short link, or number (#123).
#
# Read:
#   trello.sh whoami                          Who the token belongs to
#   trello.sh boards                          My open boards (to find a board's short link)
#   trello.sh lists | labels | members        The board's lists, labels, members
#   trello.sh custom-fields                   The board's custom fields
#   trello.sh cards [LIST] [--mine]           Open cards, grouped by list
#   trello.sh my-cards [--all]                Cards assigned to me (this board, or --all boards)
#   trello.sh card CARD                       Everything about a card: description, checklists,
#                                             custom fields, attachments, all comments
#   trello.sh download CARD [DIR]             Download the card's uploaded attachments
#   trello.sh search TEXT                     Search cards on this board
#   trello.sh my-time [FROM] [TO] [--all]     My logged time (YYYY-MM-DD, default today)
# Write (confirm with the user first):
#   trello.sh create LIST "TITLE" [--desc TEXT] [--label NAME]... [--member WHO]... [--due DATE] [--top]
#   trello.sh move CARD LIST                  LIST = list name or a key from trello.lists (e.g. doing)
#   trello.sh comment CARD "TEXT"             Or --file PATH for long text
#   trello.sh assign CARD [WHO]               WHO = me (default), @username, or full name
#   trello.sh unassign CARD [WHO]
#   trello.sh label CARD NAME | unlabel CARD NAME
#   trello.sh due CARD DATE|none | complete CARD
#   trello.sh check CARD "ITEM TEXT"          Tick a checklist item (text match)
#   trello.sh rename CARD "TITLE" | describe CARD --file PATH
#   trello.sh log-time CARD HOURS [--date YYYY-MM-DD] [--comment TEXT]
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

load_workspace

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 1; }

# Time log comments look like: "⏱ Logged 1.5h on 2026-10-26 - Built the login form"
TIME_MARK="⏱ Logged"

cmd="${1:-}"; [[ -n "$cmd" ]] || usage; shift
# whoami and boards work before a board is configured (they are how you find it).
case "$cmd" in whoami|boards|my-cards) B="" ;; *) B="$(board_id)" ;; esac

card_fields="name,desc,idList,idMembers,labels,due,dueComplete,shortLink,idShort,url,dateLastActivity,closed"

case "$cmd" in
  whoami)
    trello_api GET "/members/me?fields=fullName,username,id" | jq -r '"\(.fullName) (@\(.username)) id=\(.id)"'
    ;;

  boards)
    trello_api GET "/members/me/boards?filter=open&fields=name,shortLink,url,dateLastActivity" \
      | jq -r 'sort_by(.dateLastActivity) | reverse | .[] | "\(.shortLink)  \(.name)  \(.url)"'
    ;;

  lists)
    mapping="$(jq -c '.trello.lists // {}' "$WS_FILE")"
    trello_api GET "/boards/$B/lists?filter=open&fields=name" | jq -r --argjson m "$mapping" '
      .[] | .name as $n | "- \($n)\(([$m | to_entries[] | select(.value == $n) | .key] | join(", ")) as $k | if $k != "" then "  (= \($k))" else "" end)"'
    ;;

  labels)
    trello_api GET "/boards/$B/labels?fields=name,color&limit=1000" \
      | jq -r '.[] | "- \(if (.name // "") != "" then .name else "(no name)" end)  [\(.color // "no color")]"'
    ;;

  members)
    trello_api GET "/boards/$B/members?fields=fullName,username" | jq -r '.[] | "- \(.fullName) (@\(.username))"'
    ;;

  custom-fields)
    trello_api GET "/boards/$B/customFields" | jq -r '
      if length == 0 then "(no custom fields)" else .[] | "- \(.name) [\(.type)]\(if .options then ": " + ([.options[].value.text] | join(", ")) else "" end)" end'
    ;;

  cards)
    list_filter=""; mine=""
    for a in "$@"; do
      if [[ "$a" == --mine ]]; then mine=1; else list_filter="$a"; fi
    done
    me=""; [[ -n "$mine" ]] && me="$(resolve_member me)"
    lid=""; [[ -n "$list_filter" ]] && lid="$(resolve_list "$list_filter")"
    lists="$(trello_api GET "/boards/$B/lists?filter=open&fields=name")"
    trello_api GET "/boards/$B/cards/open?fields=$card_fields&members=true&member_fields=username" \
      | jq -r --argjson lists "$lists" --arg me "$me" --arg lid "$lid" '
        ($lists | map({(.id): .name}) | add // {}) as $ln
        | [.[] | select($me == "" or (.idMembers | index($me))) | select($lid == "" or .idList == $lid)]
        | if length == 0 then "(no cards)" else
          group_by(.idList)[] | "== \($ln[.[0].idList] // "?")",
          (.[] | "  #\(.idShort) \(.name)\(if (.labels | length) > 0 then "  [" + ([.labels[] | (if (.name // "") != "" then .name else .color end)] | join(", ")) + "]" else "" end)\(if (.members | length) > 0 then "  @" + ([.members[].username] | join(" @")) else "" end)\(if .due then "  due " + .due[0:10] + (if .dueComplete then " (done)" else "" end) else "" end)")
        end'
    ;;

  my-cards)
    if [[ "${1:-}" == --all ]]; then
      cards="$(trello_api GET "/members/me/cards?filter=open&fields=$card_fields,idBoard")"
      boards="$(trello_api GET "/members/me/boards?fields=name")"
      jq -r --argjson b "$boards" '($b | map({(.id): .name}) | add // {}) as $bn
        | if length == 0 then "(no cards assigned to you)" else
          group_by(.idBoard)[] | "== \($bn[.[0].idBoard] // "?")", (.[] | "  #\(.idShort) \(.name)  \(.url)") end' <<<"$cards"
    else
      exec "$0" cards --mine
    fi
    ;;

  card)
    c="$(resolve_card "${1:?card required}")"
    card="$(trello_api GET "/cards/$c?fields=all&checklists=all&attachments=true&members=true&member_fields=fullName,username&customFieldItems=true&list=true&board=true&board_fields=name&actions=commentCard,updateCard:idList,createCard&actions_limit=1000")"
    fields="$(trello_api GET "/boards/$B/customFields" 2>/dev/null || echo '[]')"
    jq -r --argjson cf "$fields" --arg mark "$TIME_MARK" '
      . as $c |
      ($cf | map({(.id): .}) | add // {}) as $defs |
      "#\($c.idShort) \($c.name)",
      "List: \($c.list.name // "-") | Board: \($c.board.name // "-")\(if $c.closed then " | ARCHIVED" else "" end)",
      "Members: \(([$c.members[]? | "\(.fullName) (@\(.username))"] | join(", ")) | if . == "" then "-" else . end)",
      "Labels: \(([$c.labels[]? | (if (.name // "") != "" then .name else .color end)] | join(", ")) | if . == "" then "-" else . end)",
      "Due: \(if $c.due then $c.due[0:16] + (if $c.dueComplete then " (complete)" else "" end) else "-" end) | Last activity: \($c.dateLastActivity[0:16])",
      "Link: \($c.url)",
      "",
      "## Description",
      (($c.desc // "") | if . == "" then "(empty)" else . end),
      "",
      "## Checklists",
      (($c.checklists // []) | if length == 0 then "(none)" else (.[] |
        "### \(.name)", (.checkItems | sort_by(.pos)[] | "- [\(if .state == "complete" then "x" else " " end)] \(.name)")) end),
      "",
      "## Custom fields",
      ([($c.customFieldItems // [])[] | . as $i | ($defs[$i.idCustomField] // {}) as $d |
          {name: ($d.name // $i.idCustomField),
           value: (if $i.idValue then ([$d.options[]? | select(.id == $i.idValue) | .value.text][0] // $i.idValue)
                   else ($i.value | to_entries[0].value | tostring) end)}]
        | if length == 0 then "(none)" else (.[] | "- \(.name): \(.value)") end),
      "",
      "## Attachments (download uploaded files: trello.sh download \($c.shortLink))",
      (($c.attachments // []) | if length == 0 then "(none)" else (.[] |
        "- \(.name)\(if .isUpload then " (uploaded, \(.bytes // 0) bytes, \(.mimeType // "-"))" else " (link)" end)  \(.url)") end),
      "",
      "## Activity",
      ([($c.actions // [])[] | select(.type == "commentCard" or .type == "updateCard" or .type == "createCard")] | reverse
        | if length == 0 then "(none)" else (.[] |
          if .type == "commentCard" then "--- \(.memberCreator.fullName) at \(.date[0:16])\(if (.data.text | startswith($mark)) then " (time log)" else "" end)\n\(.data.text)"
          elif .type == "createCard" then "--- created by \(.memberCreator.fullName) at \(.date[0:16])"
          else "--- \(.memberCreator.fullName) moved it \(.data.listBefore.name // "?") -> \(.data.listAfter.name // "?") at \(.date[0:16])" end) end)
    ' <<<"$card"
    ;;

  download)
    c="$(resolve_card "${1:?card required}")"
    card="$(trello_api GET "/cards/$c?fields=id,shortLink&attachments=true")"
    id="$(jq -r .id <<<"$card")"; short="$(jq -r .shortLink <<<"$card")"
    dir="${2:-.trello-attachments/$short}"
    mkdir -p "$dir"
    n=0
    while IFS=$'\t' read -r aid fname; do
      [[ -n "$aid" ]] || continue
      safe="$(basename "$fname")"
      trello_api GET "/cards/$id/attachments/$aid/download/$(urlencode "$fname")" -o "$dir/$safe" -H "Accept: */*"
      echo "Saved $dir/$safe"; n=$((n + 1))
    done < <(jq -r '.attachments[] | select(.isUpload) | [.id, .fileName // .name] | @tsv' <<<"$card")
    [[ $n -gt 0 ]] || echo "(no uploaded attachments)"
    ;;

  search)
    q="${1:?search text required}"
    board_full="$(trello_api GET "/boards/$B?fields=id")"
    trello_api GET "/search?query=$(urlencode "$q")&idBoards=$(jq -r .id <<<"$board_full")&modelTypes=cards&cards_limit=30&card_fields=name,idShort,shortLink,closed&card_list=true" \
      | jq -r '.cards | if length == 0 then "(no matches)" else (.[] | "#\(.idShort) \(.name)  [\(.list.name // "-")]\(if .closed then " (archived)" else "" end)") end'
    ;;

  my-time)
    from=""; to=""; all=""
    for a in "$@"; do
      if [[ "$a" == --all ]]; then all=1; elif [[ -z "$from" ]]; then from="$a"; else to="$a"; fi
    done
    from="${from:-$(date +%Y-%m-%d)}"; to="${to:-$from}"
    # Comments can be written a while after the day they log, so look back a month further.
    since="$(date -j -v-31d -f %Y-%m-%d "$from" +%Y-%m-%d 2>/dev/null || date -d "$from -31 days" +%Y-%m-%d)"
    board_full="$(trello_api GET "/boards/$B?fields=id")"
    trello_api GET "/members/me/actions?filter=commentCard&since=${since}T00:00:00Z&limit=1000" \
      | jq -r --arg mark "$TIME_MARK" --arg from "$from" --arg to "$to" --arg board "$(jq -r .id <<<"$board_full")" --arg all "$all" '
        [.[] | select($all == "1" or .data.board.id == $board)
         | .data.text as $t | ($t | capture("^" + $mark + " (?<h>[0-9.]+)h on (?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})(?: - (?<c>.*))?")?) as $m
         | select($m != null) | select($m.d >= $from and $m.d <= $to)
         | {date: $m.d, hours: ($m.h | tonumber), comment: ($m.c // ""), card: "#\(.data.card.idShort) \(.data.card.name)", board: .data.board.name}]
        | if length == 0 then "(no time logged in this range)" else
          (sort_by(.date) | group_by(.date)[] |
            "\(.[0].date)  total \(map(.hours) | add * 100 | round / 100)h",
            (.[] | "  \(.hours)h  \(.card)\(if $all == "1" then "  (" + .board + ")" else "" end)\(if .comment != "" then "  - " + .comment else "" end)")),
          "Range total: \(map(.hours) | add * 100 | round / 100)h" end'
    ;;

  # ---------- writes ----------

  create)
    list="${1:?list required}"; title="${2:?title required}"; shift 2
    lid="$(resolve_list "$list")"
    args=(--data-urlencode "idList=$lid" --data-urlencode "name=$title")
    pos=bottom
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --desc) args+=(--data-urlencode "desc=$2"); shift 2 ;;
        --desc-file) args+=(--data-urlencode "desc@$2"); shift 2 ;;
        --label) args+=(--data-urlencode "idLabels=$(resolve_label "$2")"); shift 2 ;;
        --member) args+=(--data-urlencode "idMembers=$(resolve_member "$2")"); shift 2 ;;
        --due) args+=(--data-urlencode "due=$2"); shift 2 ;;
        --top) pos=top; shift ;;
        *) die "unknown option for create: $1" ;;
      esac
    done
    # Trello wants one comma-separated value per id field.
    labels=(); members=(); rest=()
    for ((i = 0; i < ${#args[@]}; i += 2)); do
      v="${args[i+1]}"
      case "$v" in
        idLabels=*) labels+=("${v#idLabels=}") ;;
        idMembers=*) members+=("${v#idMembers=}") ;;
        *) rest+=("${args[i]}" "$v") ;;
      esac
    done
    [[ ${#labels[@]} -gt 0 ]] && rest+=(--data-urlencode "idLabels=$(IFS=,; echo "${labels[*]}")")
    [[ ${#members[@]} -gt 0 ]] && rest+=(--data-urlencode "idMembers=$(IFS=,; echo "${members[*]}")")
    trello_api POST "/cards" "${rest[@]}" --data-urlencode "pos=$pos" \
      | jq -r '"Created #\(.idShort) \(.name)\n\(.url)"'
    ;;

  move)
    c="$(resolve_card "${1:?card required}")"; lid="$(resolve_list "${2:?list required}")"
    trello_api PUT "/cards/$c" --data-urlencode "idList=$lid" --data-urlencode "pos=top" >/dev/null
    echo "Moved card to ${2}"
    ;;

  comment)
    c="$(resolve_card "${1:?card required}")"; shift
    if [[ "${1:-}" == --file ]]; then text="$(cat "${2:?file required}")"; else text="${1:?comment text required}"; fi
    trello_api POST "/cards/$c/actions/comments" --data-urlencode "text=$text" >/dev/null
    echo "Comment added"
    ;;

  assign|unassign)
    c="$(resolve_card "${1:?card required}")"; mid="$(resolve_member "${2:-me}")"
    if [[ "$cmd" == assign ]]; then
      trello_api POST "/cards/$c/idMembers" --data-urlencode "value=$mid" >/dev/null; echo "Assigned ${2:-me}"
    else
      trello_api DELETE "/cards/$c/idMembers/$mid" >/dev/null; echo "Unassigned ${2:-me}"
    fi
    ;;

  label|unlabel)
    c="$(resolve_card "${1:?card required}")"; lab="$(resolve_label "${2:?label required}")"
    if [[ "$cmd" == label ]]; then
      trello_api POST "/cards/$c/idLabels" --data-urlencode "value=$lab" >/dev/null; echo "Label added"
    else
      trello_api DELETE "/cards/$c/idLabels/$lab" >/dev/null; echo "Label removed"
    fi
    ;;

  due)
    c="$(resolve_card "${1:?card required}")"; d="${2:?date or none required}"
    [[ "$d" == none ]] && d=""
    trello_api PUT "/cards/$c" --data-urlencode "due=$d" >/dev/null; echo "Due date ${d:-cleared}"
    ;;

  complete)
    c="$(resolve_card "${1:?card required}")"
    trello_api PUT "/cards/$c" --data-urlencode "dueComplete=true" >/dev/null; echo "Marked complete"
    ;;

  check)
    c="$(resolve_card "${1:?card required}")"; item="${2:?checklist item text required}"
    card="$(trello_api GET "/cards/$c?fields=id&checklists=all")"
    matches="$(jq -c --arg t "$item" '[.checklists[].checkItems[] | select(.name | ascii_downcase | contains($t | ascii_downcase))]' <<<"$card")"
    count="$(jq length <<<"$matches")"
    [[ "$count" -eq 1 ]] || die "\"$item\" matches $count checklist items: $(jq -r '[.[].name] | join(" | ")' <<<"$matches")"
    trello_api PUT "/cards/$(jq -r .id <<<"$card")/checkItem/$(jq -r '.[0].id' <<<"$matches")" --data-urlencode "state=complete" >/dev/null
    echo "Ticked: $(jq -r '.[0].name' <<<"$matches")"
    ;;

  rename)
    c="$(resolve_card "${1:?card required}")"
    trello_api PUT "/cards/$c" --data-urlencode "name=${2:?title required}" >/dev/null; echo "Renamed"
    ;;

  describe)
    c="$(resolve_card "${1:?card required}")"
    [[ "${2:-}" == --file ]] || die "usage: trello.sh describe CARD --file PATH"
    trello_api PUT "/cards/$c" --data-urlencode "desc@${3:?file required}" >/dev/null; echo "Description updated"
    ;;

  log-time)
    c="$(resolve_card "${1:?card required}")"; hours="${2:?hours required}"; shift 2
    [[ "$hours" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "hours must be a number like 1.5"
    day="$(date +%Y-%m-%d)"; note=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --date) day="$2"; shift 2 ;;
        --comment) note="$2"; shift 2 ;;
        *) die "unknown option for log-time: $1" ;;
      esac
    done
    [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "date must be YYYY-MM-DD"
    if [[ "$(ws_get .worklog.requireComment)" == true && -z "$note" ]]; then die "this workspace requires --comment"; fi
    text="$TIME_MARK ${hours}h on $day"; [[ -n "$note" ]] && text+=" - $note"
    trello_api POST "/cards/$c/actions/comments" --data-urlencode "text=$text" >/dev/null
    echo "Logged: $text"
    # Optional: also add the hours to a number custom field (e.g. "Time spent").
    cfname="$(ws_get .worklog.customField)"
    if [[ -n "$cfname" ]]; then
      cf="$(trello_api GET "/boards/$B/customFields" | jq -r --arg n "$cfname" '[.[] | select(.name == $n and .type == "number")][0].id // empty')"
      if [[ -z "$cf" ]]; then
        warn "no number custom field \"$cfname\" on the board; only the comment was added"
      else
        cid="$(trello_api GET "/cards/$c?fields=id" | jq -r .id)"
        current="$(trello_api GET "/cards/$cid/customFieldItems" | jq -r --arg f "$cf" '[.[] | select(.idCustomField == $f)][0].value.number // "0"')"
        total="$(jq -n --arg a "$current" --arg b "$hours" '($a | tonumber) + ($b | tonumber) | . * 100 | round / 100')"
        trello_api PUT "/cards/$cid/customField/$cf/item" -H "Content-Type: application/json" \
          -d "$(jq -cn --arg v "$total" '{value: {number: $v}}')" >/dev/null
        echo "$cfname: $current -> $total"
      fi
    fi
    ;;

  *) usage ;;
esac
