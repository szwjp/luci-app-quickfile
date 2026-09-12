#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Detect whether https://r2.cooluc.com/source has a quickfile release newer
# than the PKG_VERSION pinned in luci-app-quickfile/Makefile, and track it in
# exactly one GitHub issue. Detection only: this never modifies the repository
# and never publishes anything. Adopting a new version stays a reviewed manual
# change (see README, "构建与校验").
#
# r2 exposes no bucket listing, so newer versions are found by probing version
# candidates: the next patches, the next minor and the next major. Missing a
# release only means no notification.
#
# Environment:
#   UPSTREAM_BASE  default https://r2.cooluc.com/source
#   LABEL          issue label, default upstream-update
#   PINNED         override the pinned version (for tests)
#   PROBE_WINDOW   how many patch versions to probe, default 15
#   DRY_RUN=1      print the planned actions, change nothing
#
# Exit status: 0 when the check ran (with or without a new release), 1 when the
# pinned release is gone upstream and no newer release was found (that breaks
# the release build and nothing could be reported about it).

set -o errexit
set -o pipefail
set -o nounset

UPSTREAM_BASE="${UPSTREAM_BASE:-https://r2.cooluc.com/source}"
LABEL="${LABEL:-upstream-update}"
PROBE_WINDOW="${PROBE_WINDOW:-15}"
DRY_RUN="${DRY_RUN:-0}"
REPO_SLUG="${GITHUB_REPOSITORY:-}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="${TMPDIR:-/tmp}"

log() { printf '%s\n' "$*"; }
notice() { printf '::notice::%s\n' "$*"; }
warning() { printf '::warning::%s\n' "$*"; }

upstream_exists() { # <version>
	local code
	code="$(curl -sIfL -o /dev/null -w '%{http_code}' --max-time 15 "$UPSTREAM_BASE/quickfile-$1.tar.gz" || echo 000)"
	[ "$code" = "200" ]
}

version_gt() { # <a> > <b> ?
	[ "$1" != "$2" ] || return 1
	awk -v a="$1" -v b="$2" 'BEGIN {
		n = split(a, x, "."); split(b, y, ".")
		for (i = 1; i <= n; i++) {
			if (x[i] + 0 > y[i] + 0) exit 0
			if (x[i] + 0 < y[i] + 0) exit 1
		}
		exit 1
	}'
}

if [ -z "${PINNED:-}" ]; then
	PINNED="$(sed -n 's/^PKG_VERSION:=//p' "$REPO_DIR/luci-app-quickfile/Makefile" | head -n1 | tr -d '[:space:]')"
fi
case "$PINNED" in
[0-9]*.[0-9]*.[0-9]*) ;;
*)
	warning "cannot parse PKG_VERSION (got '$PINNED')"
	exit 1
	;;
esac

IFS=. read -r major minor patch <<<"$PINNED"

candidates=()
for i in $(seq 1 "$PROBE_WINDOW"); do
	candidates+=("$major.$minor.$((patch + i))")
done
candidates+=("$major.$((minor + 1)).0" "$((major + 1)).0.0")

latest=""
for candidate in "${candidates[@]}"; do
	upstream_exists "$candidate" || continue
	log "  upstream has quickfile-$candidate.tar.gz"
	if [ -z "$latest" ] || version_gt "$candidate" "$latest"; then
		latest="$candidate"
	fi
done

pinned_available=yes
if ! upstream_exists "$PINNED"; then
	pinned_available=no
	warning "pinned quickfile-$PINNED.tar.gz is not available at $UPSTREAM_BASE"
fi

log "pinned=$PINNED (available: $pinned_available) latest=${latest:-<none>} probed=${#candidates[@]}"

tracking_issue() { # "<number>\t<title>" of the newest open tracking issue, or empty
	# `// empty` matters: without it jq interpolates the null of an empty list
	# into the string "null\tnull" and this script would close issue #null.
	if [ -n "$REPO_SLUG" ]; then
		gh issue list --repo "$REPO_SLUG" --label "$LABEL" --state open --limit 1 \
			--json number,title --jq '.[0] // empty | "\(.number)\t\(.title)"' 2>/dev/null || true
	else
		gh issue list --label "$LABEL" --state open --limit 1 \
			--json number,title --jq '.[0] // empty | "\(.number)\t\(.title)"' 2>/dev/null || true
	fi
}

gh_issue() { # passthrough that honours DRY_RUN
	if [ "$DRY_RUN" = "1" ]; then
		log "  [dry-run] gh issue $*"
		return 0
	fi
	if [ -n "$REPO_SLUG" ]; then
		gh issue "$@" --repo "$REPO_SLUG"
	else
		gh issue "$@"
	fi
}

existing="$(tracking_issue)"
existing_number="$(printf '%s' "$existing" | cut -f1)"
existing_title="$(printf '%s' "$existing" | cut -f2-)"

if [ -z "$latest" ]; then
	if [ "$pinned_available" = "no" ]; then
		warning "the pinned release is gone and no newer release was found; the release build will fail (set QUICKFILE_SKIP_UPSTREAM_VERIFY=1 only to build offline)"
		exit 1
	fi
	if [ -n "$existing_number" ]; then
		log "nothing newer upstream; closing tracking issue #$existing_number"
		gh_issue comment "$existing_number" --body "仓库已跟到 \`$PINNED\`，上游没有更新的版本，自动关闭。"
		gh_issue close "$existing_number"
	else
		log "nothing newer upstream and no tracking issue; nothing to do"
	fi
	exit 0
fi

want_title="upstream quickfile $latest available"

if [ -n "$existing_number" ] && [ "$existing_title" = "$want_title" ]; then
	notice "issue #$existing_number already tracks upstream $latest"
	exit 0
fi

# Report the upstream tarball hash so it can be pasted into quickfile/Makefile
# as PKG_HASH.
new_hash=""
if curl -fsSL --retry 3 --max-time 300 -o "$TMP_DIR/upstream-quickfile.tar.gz" \
	"$UPSTREAM_BASE/quickfile-$latest.tar.gz"; then
	new_hash="$(sha256sum "$TMP_DIR/upstream-quickfile.tar.gz" | cut -d' ' -f1)"
else
	warning "cannot download quickfile-$latest.tar.gz; reporting without its hash"
fi

body_file="$TMP_DIR/upstream-issue-body.md"
# The single quotes are intentional: these are printf format strings with
# literal Markdown backticks; %s is expanded by printf, not by the shell.
# shellcheck disable=SC2016
{
	printf 'r2.cooluc.com 上有比仓库当前 pin 更新的 quickfile 版本。\n\n'
	printf '| 项 | 值 |\n|---|---|\n'
	printf '| 仓库 pin（`PKG_VERSION`） | `%s` |\n' "$PINNED"
	printf '| 上游最新 | `%s` |\n' "$latest"
	printf '| 上游包 sha256（可直接用作 `PKG_HASH`） | `%s` |\n\n' "${new_hash:-下载失败，请自行计算}"
	if [ "$pinned_available" = "no" ]; then
		printf '> ⚠️ 当前 pin 的 `quickfile-%s.tar.gz` 已从上游下架，**下次发布构建会直接失败**，需要尽快跟版。\n\n' "$PINNED"
	fi
	printf '本 issue 由 `.github/workflows/check-upstream.yml` 每日探测自动创建/更新，**只做检测，不会改动仓库、不会发布**。跟版是人工且需要 review 的改动：\n\n'
	printf '1. 下载上游 `quickfile-%s.tar.gz`，取出其中的 `quickfile-%s/quickfile.x86_64`，重新打包成 `vendor/quickfile/quickfile-%s-x86_64.tar.gz`；\n' "$latest" "$latest" "$latest"
	printf '2. 刷新 `vendor/quickfile/SHA256SUMS`；\n'
	printf '3. 两个 Makefile 的 `PKG_VERSION` 都改为 `%s`，`quickfile/Makefile` 的 `PKG_HASH` 改为上表的 sha256，`PKG_RELEASE` 重置为 1；\n' "$latest"
	printf '4. 提交后手动触发 Build workflow：构建时会再次下载上游包，并按 `PKG_HASH` 与二进制逐字节校验。\n\n'
	printf '合并并发布后，下一次探测会自动关闭本 issue。\n'
} > "$body_file"

if [ -n "$existing_number" ]; then
	log "updating tracking issue #$existing_number ('$existing_title' -> '$want_title')"
	gh_issue comment "$existing_number" --body-file "$body_file"
	gh_issue edit "$existing_number" --title "$want_title"
	notice "tracking issue #$existing_number updated to upstream $latest"
else
	log "creating tracking issue '$want_title'"
	gh_issue create --title "$want_title" --label "$LABEL" --body-file "$body_file"
	notice "created tracking issue for upstream $latest"
fi
