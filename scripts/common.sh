#!/usr/bin/env bash
# Shared helpers for the redmine-workflow scripts.
# Secrets come from the environment (for example via direnv).
# Per-project settings come from .redmine-workspace.json (no secrets in it).

set -euo pipefail

# Shells that don't run the direnv hook (scripts, agents, CI) still get the project's .envrc:
# re-run this script once through `direnv exec` when the current folder has an allowed .envrc.
if [[ -z "${WORKFLOW_DIRENV_LOADED:-}" ]] && command -v direnv >/dev/null 2>&1 \
  && [[ "$(direnv status 2>/dev/null)" == *$'\nFound RC allowed 0'* ]]; then
  export WORKFLOW_DIRENV_LOADED=1
  exec direnv exec "$PWD" bash "$0" "$@"
fi

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_NAME=".redmine-workspace.json"
WS_FILE="${WS_FILE:-}"

die() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is not installed. $2"; }

need jq "Install it with: brew install jq"

# Find .redmine-workspace.json in the current folder or a parent folder.
# REDMINE_WORKSPACE_FILE overrides the search.
find_workspace() {
  if [[ -n "${REDMINE_WORKSPACE_FILE:-}" ]]; then
    [[ -f "$REDMINE_WORKSPACE_FILE" ]] || { echo "error: REDMINE_WORKSPACE_FILE points to a missing file: $REDMINE_WORKSPACE_FILE" >&2; return 1; }
    echo "$REDMINE_WORKSPACE_FILE"
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

# ws_get '.redmine.project' -> value or empty string
ws_get() { jq -r "$1 // empty" "$WS_FILE"; }

urlencode() { jq -rn --arg v "$1" '$v | @uri'; }

# ---------- Redmine ----------

# Point redmine-cli at this project. Environment variables already set win,
# so a one-off REDMINE_SERVER=... still works.
redmine_env() {
  need redmine "Install it with: brew install aarondpn/tap/redmine"
  local server project
  server="$(ws_get .redmine.server)"
  project="$(ws_get .redmine.project)"
  [[ -n "${REDMINE_SERVER:-}" || -n "$server" ]] || die "redmine.server is missing in $WS_FILE"
  export REDMINE_SERVER="${REDMINE_SERVER:-${server%/}}"
  [[ -n "$project" ]] && export REDMINE_DEFAULT_PROJECT="${REDMINE_DEFAULT_PROJECT:-$project}"
  if [[ "$(ws_get .redmine.readOnly)" == "true" ]]; then export REDMINE_READ_ONLY="${REDMINE_READ_ONLY:-1}"; fi
  export REDMINE_AUTH_METHOD="${REDMINE_AUTH_METHOD:-apikey}"
  export REDMINE_NO_UPDATE_CHECK=1
  if [[ "$REDMINE_AUTH_METHOD" == apikey ]]; then
    [[ -n "${REDMINE_API_KEY:-}" ]] || die "REDMINE_API_KEY is not set. Add it to your .envrc and run: direnv allow"
  fi
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
  local authcfg; authcfg="$(bb_authcfg)"
  curl -sS -L --fail-with-body -K <(echo "$authcfg") "$url" "$@"
}
