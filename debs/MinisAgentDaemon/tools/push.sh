#!/bin/sh
# Copy the project into the CI repo clone and push it to the given branch.
# Keeps the token substitution out of the caller's command line.
set -eu
SRC="${1:?source dir}"
CLONE="${2:?clone dir}"
BRANCH="${3:?branch}"
TOKEN="${GITHUB_TOKEN_QQ:?}"
AUTH="Authorization: Basic $(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"

mkdir -p "$CLONE/debs/MinisAgentDaemon"
rm -rf "$CLONE/debs/MinisAgentDaemon"
mkdir -p "$CLONE/debs/MinisAgentDaemon"
cd "$SRC"
find . -type f ! -path './.theos/*' ! -name 'probe*' ! -name '*.deb' -exec cp --parents {} "$CLONE/debs/MinisAgentDaemon/" \;

cd "$CLONE"
git add debs/MinisAgentDaemon
git -c user.name=niubiprass -c user.email=niubiprass@users.noreply.github.com \
    commit -q -m "${4:-agentd: update}"
git -c credential.helper= -c http.extraHeader="$AUTH" push origin "HEAD:refs/heads/$BRANCH"
