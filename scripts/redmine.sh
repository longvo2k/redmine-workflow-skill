#!/usr/bin/env bash
# Run redmine-cli with this project's server and default project.
# Usage: redmine.sh <any redmine-cli arguments>
#   redmine.sh issues list --assignee me
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

load_workspace
redmine_env
exec redmine "$@"
