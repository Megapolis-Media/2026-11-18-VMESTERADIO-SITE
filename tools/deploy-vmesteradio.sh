#!/usr/bin/env bash
set -euo pipefail

revision=${SSH_ORIGINAL_COMMAND:-}
if [[ ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
  echo 'Expected a full Git commit SHA' >&2
  exit 2
fi

state=/srv/vmesteradio-production
repo="$state/source.git"
site="$state/www"
releases="$site/releases"
release="$releases/$revision"
upstream=https://github.com/Megapolis-Media/2026-11-18-VMESTERADIO-SITE.git

exec 9>"$state/publish.lock"
flock -w 90 9
git --git-dir="$repo" fetch --no-tags "$upstream" refs/heads/master
if [[ "$(git --git-dir="$repo" rev-parse FETCH_HEAD)" != "$revision" ]]; then
  echo 'The requested commit is no longer the head of master' >&2
  exit 1
fi

tree="$(git --git-dir="$repo" ls-tree -r "$revision" -- public/)"
if [[ -z "$tree" ]] || grep -qvE '^100(644|755) blob ' <<< "$tree"; then
  echo 'The public directory must contain regular files from master' >&2
  exit 1
fi

staging=
next_link="$site/.next-release"
previous="$(readlink "$site/current" || true)"
verify_pending=false
activate() {
  ln -s -- "$1" "$next_link"
  mv -Tf -- "$next_link" "$site/current"
}

cleanup() {
  rm -f -- "$next_link"
  if [[ "$verify_pending" == true ]]; then
    if [[ -n "$previous" ]]; then
      activate "$previous"
    else
      rm -f -- "$site/current"
    fi
  fi
  if [[ -n "$staging" ]]; then
    rm -rf -- "$staging"
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if [[ ! -d "$release" ]]; then
  staging="$(mktemp -d "$releases/.stage.XXXXXX")"
  chmod 755 "$staging"
  git --git-dir="$repo" archive "$revision" public | tar -x -C "$staging"
  test -s "$staging/public/index.html"
  test -s "$staging/public/styles.css"
  mv -T -- "$staging" "$release"
  staging=
fi

verify_pending=true
activate "releases/$revision/public"
if ! curl --fail --silent --show-error --max-time 10 http://127.0.0.1:18175/ |
    cmp -s - "$release/public/index.html" ||
   ! curl --fail --silent --show-error --max-time 10 http://127.0.0.1:18175/styles.css |
    cmp -s - "$release/public/styles.css"; then
  echo 'The served files failed verification. Rolling back.' >&2
  exit 1
fi
verify_pending=false

printf 'Published master at %s\n' "$revision"
