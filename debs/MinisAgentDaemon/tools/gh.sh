#!/bin/sh
# GitHub helper: keeps the token out of the command line and avoids $( ) in
# the caller.
set -eu
TOKEN="${GITHUB_TOKEN_QQ:?}"
AUTH="Authorization: Basic $(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"
case "${1:-}" in
runs)
    curl -s -H "$AUTH" "https://api.github.com/repos/HGFdel-dav/theos-ci/actions/runs?branch=${2:-agentd-0.2.0-ci}&per_page=5"
    ;;
run)
    curl -s -H "$AUTH" "https://api.github.com/repos/HGFdel-dav/theos-ci/actions/runs/$2"
    ;;
jobs)
    curl -s -H "$AUTH" "https://api.github.com/repos/HGFdel-dav/theos-ci/actions/runs/$2/jobs"
    ;;
log)
    curl -sL -H "$AUTH" "https://api.github.com/repos/HGFdel-dav/theos-ci/actions/runs/$2/logs" -o "$3"
    ;;
artifacts)
    curl -s -H "$AUTH" "https://api.github.com/repos/HGFdel-dav/theos-ci/actions/runs/$2/artifacts"
    ;;
*)
    echo "usage: gh.sh runs|run|jobs|log|artifacts ID" >&2
    exit 64
    ;;
esac
