#!/bin/bash
# ---------------------------------------------------------------------
# push_to_github.sh  --  create a private GitHub repository and push
#
#   bash push_to_github.sh
#
# Uses the GitHub account your gh command is signed in to, and your
# own git name and email for the commit.
# ---------------------------------------------------------------------
set -e
cd "$(dirname "$0")"

if ! command -v gh >/dev/null 2>&1; then
    echo "The GitHub command line tool is missing. Run:  brew install gh"
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "gh is not signed in. Run:  gh auth login"
    exit 1
fi

if [ ! -d .git ]; then
    git init -q -b main
fi
git add -A
if ! git diff --cached --quiet; then
    git commit -q -m "Add Pascal order desk with forms manager and PostgreSQL procedures"
fi

if git remote get-url origin >/dev/null 2>&1; then
    git push -u origin main
else
    gh repo create pascal-order-desk --private --source=. --remote=origin --push \
        --description "Forms-based order desk in Pascal with PostgreSQL stored procedures and parallel session tests"
fi

gh repo view --json url --jq '"Pushed to " + .url'
