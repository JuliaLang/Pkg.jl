#!/usr/bin/env bash
# Vendor Resolver.jl into vendor/Resolver, or check that the vendored copy
# matches the commit recorded in vendor/Resolver.version.
#
#   vendor/update_resolver.sh [--from URL|PATH] [--commit] [REV]
#       Replace vendor/Resolver with REV (default: main) of the upstream repo,
#       or of the repo given by --from (e.g. a local checkout), and record its
#       commit. --commit also commits the result with the upstream shortlog.
#   vendor/update_resolver.sh --check
#       Fail if vendor/Resolver differs from the recorded commit.
set -euo pipefail

VENDOR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VERSION_FILE="$VENDOR_DIR/Resolver.version"
DEST="$VENDOR_DIR/Resolver"
PATHS=(src LICENSE.md Project.toml)

field() { sed -n "s/^$1 *= *//p" "$VERSION_FILE"; }
URL=$(field RESOLVER_URL)
OLD_SHA1=$(field RESOLVER_SHA1)

check=false commit=false rev=main from=$URL
while [ $# -gt 0 ]; do
    case $1 in
        --check) check=true ;;
        --commit) commit=true ;;
        --from) from=$2; shift ;;
        -*) echo "unknown option: $1" >&2; exit 1 ;;
        *) rev=$1 ;;
    esac
    shift
done
# a relative --from path is relative to the caller, not to the scratch repo
[ -d "$from" ] && from=$(cd "$from" && pwd)

# Fetch into a scratch repo so the objects stay out of the Pkg repo.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git init -q --bare "$TMP/repo"
fetch() { git -C "$TMP/repo" fetch -q --no-tags "$@"; }
extract() { mkdir -p "$2"; git -C "$TMP/repo" archive "$1" "${PATHS[@]}" | tar -x -C "$2"; }

if $check; then
    fetch --depth=1 "$URL" "$OLD_SHA1"
    extract "$OLD_SHA1" "$TMP/expected"
    if ! diff -r "$TMP/expected" "$DEST"; then
        echo "vendor/Resolver differs from $URL at $OLD_SHA1;" \
            "edit Resolver.jl upstream and run vendor/update_resolver.sh" >&2
        exit 1
    fi
    echo "vendor/Resolver matches $URL at $OLD_SHA1"
    exit 0
fi

# Fetch all branches and tags so REV may be a branch, tag or (abbreviated) sha;
# a commit on no branch must be given in full.
fetch "$from" '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'
if ! NEW_SHA1=$(git -C "$TMP/repo" rev-parse -q --verify "$rev^{commit}"); then
    fetch "$from" "$rev"
    NEW_SHA1=$(git -C "$TMP/repo" rev-parse FETCH_HEAD)
fi
rm -rf "$DEST"
extract "$NEW_SHA1" "$DEST"
sed -i.bak "s/^RESOLVER_SHA1 *=.*/RESOLVER_SHA1 = $NEW_SHA1/" "$VERSION_FILE"
rm -f "$VERSION_FILE.bak"

cd "$VENDOR_DIR"
git add -A Resolver Resolver.version
if git -C "$TMP/repo" cat-file -e "$OLD_SHA1^{commit}" 2>/dev/null; then
    log=$(git -C "$TMP/repo" log --oneline --no-decorate "$OLD_SHA1..$NEW_SHA1" -- "${PATHS[@]}")
else
    log=""
fi
msg="Update vendored Resolver.jl to ${NEW_SHA1:0:7}"
if [ -n "$log" ]; then
    msg+=$'\n\n'"Changes since ${OLD_SHA1:0:7}:"$'\n'"$log"
fi
echo "$msg"
if $commit; then
    git commit -q -m "$msg" -- Resolver Resolver.version
fi
