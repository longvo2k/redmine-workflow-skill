#!/usr/bin/env bash
# Redmine reads formatted for planning work. All commands are read-only.
#
#   redmine-api.sh requirements ID        Everything needed to start a task: description, custom fields,
#                                         parent, subtasks, relations, attachments, full history
#   redmine-api.sh my-time [FROM] [TO]    My time entries between dates (YYYY-MM-DD, default today), per day
#   redmine-api.sh activities             Time entry activities (for --activity)
#   redmine-api.sh statuses               Issue statuses
#   redmine-api.sh myself                 Who the API key belongs to
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

load_workspace
redmine_env

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 1; }
api() { redmine api "$@" -o json; }

cmd="${1:-}"; [[ -n "$cmd" ]] || usage; shift

case "$cmd" in
  requirements)
    id="${1:?issue ID required}"; id="${id#\#}"
    [[ "$id" =~ ^[0-9]+$ ]] || die "issue ID must be a number, got: $id"
    issue="$(api "/issues/$id.json" -f include=journals,children,relations,attachments)"
    parent_id="$(jq -r '.issue.parent.id // empty' <<<"$issue")"
    parent=""
    [[ -n "$parent_id" ]] && parent="$(api "/issues/$parent_id.json" 2>/dev/null | jq -r '"#\(.issue.id) [\(.issue.status.name)] \(.issue.subject)"' || echo "#$parent_id")"
    jq -r --arg parent "$parent" --arg server "$REDMINE_SERVER" '
      .issue as $i |
      def v: if type == "array" then (map(tostring) | join(", ")) else (. // "" | tostring) end;
      "#\($i.id): \($i.subject)",
      "Project: \($i.project.name) | Tracker: \($i.tracker.name) | Status: \($i.status.name) | Priority: \($i.priority.name)",
      "Assignee: \($i.assigned_to.name // "Unassigned") | Author: \($i.author.name)",
      "Version: \($i.fixed_version.name // "-") | Category: \($i.category.name // "-") | Done: \($i.done_ratio // 0)%",
      "Dates: start \($i.start_date // "-"), due \($i.due_date // "-")",
      "Time: estimated \($i.estimated_hours // "-")h, spent \($i.spent_hours // $i.total_spent_hours // "-")h",
      (if $parent != "" then "Parent: \($parent)" else empty end),
      "Link: \($server)/issues/\($i.id)",
      "",
      "## Description",
      (($i.description // "") | if . == "" then "(empty)" else . end),
      "",
      "## Custom fields",
      ([($i.custom_fields // [])[] | {name, value: (.value | v)} | select(.value != "")]
        | if length == 0 then "(none)" else (.[] | "- \(.name): \(.value)") end),
      "",
      "## Subtasks",
      (($i.children // []) | if length == 0 then "(none)" else (.[] | "- #\(.id) [\(.tracker.name)] \(.subject)") end),
      "",
      "## Relations",
      (($i.relations // []) | if length == 0 then "(none)" else (.[] |
        if .issue_id == $i.id then "- \(.relation_type) #\(.issue_to_id)" else "- #\(.issue_id) \(.relation_type) this issue" end) end),
      "",
      "## Attachments (download all: redmine.sh issues get \($i.id) --download-attachments .redmine-attachments/\($i.id))",
      (($i.attachments // []) | if length == 0 then "(none)" else (.[] | "- id \(.id): \(.filename) (\(.content_type // "-"), \(.filesize) bytes)\(if (.description // "") != "" then " - " + .description else "" end)") end),
      "",
      "## History",
      ([($i.journals // [])[] | select(((.notes // "") != "") or ((.details // []) | length > 0))]
        | if length == 0 then "(none)" else (.[] |
          "--- \(.user.name) at \(.created_on[0:16])\(if .private_notes then " (private)" else "" end)",
          ((.details // [])[] | "  * \(.name): \(.old_value // "-") -> \(.new_value // "-")"),
          (if (.notes // "") != "" then .notes else empty end)) end)
    ' <<<"$issue"
    ;;

  my-time)
    today="$(date +%Y-%m-%d)"
    from="${1:-$today}"; to="${2:-$from}"
    api /time_entries.json -f user_id=me -f from="$from" -f to="$to" -f limit=100 | jq -r '
      .time_entries | if length == 0 then "(no time logged in this range)" else
      (sort_by(.spent_on, .id) | group_by(.spent_on)[] |
        "\(.[0].spent_on)  total \(map(.hours) | add * 100 | round / 100)h",
        (.[] | "  \(.hours)h  \(if .issue then "#\(.issue.id)" else "(no issue)" end)  \(.activity.name)  \(.project.name)\(if (.comments // "") != "" then "  - " + .comments else "" end)")),
      "Range total: \(map(.hours) | add * 100 | round / 100)h" end'
    ;;

  activities)
    api /enumerations/time_entry_activities.json | jq -r '.time_entry_activities[] | "- \(.name)\(if .is_default then " (default)" else "" end)"'
    ;;

  statuses)
    api /issue_statuses.json | jq -r '.issue_statuses[] | "- \(.name)\(if .is_closed then " (closed)" else "" end)"'
    ;;

  myself)
    api /users/current.json | jq -r '.user | "\(.firstname) \(.lastname) (\(.login)) id=\(.id)"'
    ;;

  *) usage ;;
esac
