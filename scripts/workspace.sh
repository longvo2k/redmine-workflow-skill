#!/usr/bin/env bash
# Workspace setup and checks.
#
#   workspace.sh init     Create .redmine-workspace.json (and .envrc if missing) in the current folder
#   workspace.sh show     Show the active workspace settings and which secrets are set
#   workspace.sh doctor   Check tools, secrets, and that Redmine and Bitbucket accept the tokens
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 1; }
cmd="${1:-}"; [[ -n "$cmd" ]] || usage; shift

set_or_missing() { if [[ -n "${!1:-}" ]]; then echo "set"; else echo "missing"; fi; }

case "$cmd" in
  init)
    if [[ -f "$WORKSPACE_NAME" ]]; then
      echo "$WORKSPACE_NAME already exists here."
    else
      cp "$SKILL_DIR/templates/redmine-workspace.json" "$WORKSPACE_NAME"
      echo "Created $PWD/$WORKSPACE_NAME - fill in your Redmine and Bitbucket details."
    fi
    if [[ -f .envrc ]]; then
      echo ".envrc already exists. Make sure it exports the variables in $SKILL_DIR/templates/envrc.example"
    else
      cp "$SKILL_DIR/templates/envrc.example" .envrc
      echo "Created $PWD/.envrc - add your tokens, then run: direnv allow"
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
    for v in REDMINE_API_KEY BITBUCKET_EMAIL BITBUCKET_API_TOKEN BITBUCKET_ACCESS_TOKEN; do
      printf '  %-24s %s\n' "$v" "$(set_or_missing "$v")"
    done
    ;;

  doctor)
    ok=0
    pass() { echo "  ok    $*"; }
    fail() { echo "  FAIL  $*"; ok=1; }
    echo "Tools"
    for t in redmine jq curl; do command -v "$t" >/dev/null && pass "$t" || fail "$t not installed"; done
    command -v direnv >/dev/null && pass "direnv" || echo "  info  direnv not installed (optional, but recommended for tokens)"
    echo "Workspace"
    if WS_FILE="$(find_workspace 2>/dev/null)" && jq empty "$WS_FILE" 2>/dev/null; then
      pass "$WS_FILE"
      for f in .redmine.server .redmine.project; do [[ -n "$(ws_get "$f")" ]] && pass "$f = $(ws_get "$f")" || fail "$f is missing"; done
      [[ -n "$(ws_get .bitbucket.workspace)" ]] && pass ".bitbucket.workspace = $(ws_get .bitbucket.workspace)" \
        || echo "  info  no bitbucket.workspace (Bitbucket commands disabled)"
    else
      fail "no valid $WORKSPACE_NAME found (run: workspace.sh init)"
      exit 1
    fi
    echo "Secrets"
    [[ -n "${REDMINE_API_KEY:-}" ]] && pass "REDMINE_API_KEY set" || fail "REDMINE_API_KEY missing"
    echo "Redmine"
    if me="$( (redmine_env && redmine api /users/current.json -o json | jq -r '.user | "\(.firstname) \(.lastname) (\(.login))"') 2>&1)"; then
      pass "API key works - signed in as $me"
      project="$(ws_get .redmine.project)"
      if [[ -n "$project" ]]; then
        if p="$( (redmine_env && redmine api "/projects/$(urlencode "$project").json" -o json | jq -r '.project.name') 2>&1)"; then
          pass "project $project ($p)"
        else
          fail "cannot open project $project: $(echo "$p" | head -2)"
        fi
      fi
    else
      fail "Redmine rejected the request: $(echo "$me" | head -3)"
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
