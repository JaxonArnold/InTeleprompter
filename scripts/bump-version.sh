#!/bin/sh
# Bumps the version in Version.xcconfig, which the app and share extension
# both read. Archiving runs `after-archive` for you; the rest are for
# doing it by hand.
#
#   scripts/bump-version.sh build      next build number
#   scripts/bump-version.sh patch      1.1 -> 1.1.1
#   scripts/bump-version.sh minor      1.1 -> 1.2
#   scripts/bump-version.sh major      1.1 -> 2.0
#   scripts/bump-version.sh set 1.4    any version you like
set -eu

config="$(cd "$(dirname "$0")/.." && pwd)/Version.xcconfig"

current() { sed -n "s/^$1 = //p" "$config"; }
replace() { sed -i '' "s/^$1 = .*/$1 = $2/" "$config"; }

bump_build() {
    replace CURRENT_PROJECT_VERSION $(($(current CURRENT_PROJECT_VERSION) + 1))
}

bump_version() {
    replace MARKETING_VERSION "$(current MARKETING_VERSION | awk -F. -v part="$1" '{
        major = $1; minor = $2 + 0; patch = $3 + 0
        if (part == "major") { major++; minor = 0; patch = 0 }
        else if (part == "minor") { minor++; patch = 0 }
        else { patch++ }
        print (patch > 0) ? major "." minor "." patch : major "." minor
    }')"
}

case "${1:-}" in
after-archive)
    # Run by the scheme's Archive post-action, which also runs when the
    # archive failed — only a finished archive uses up its numbers.
    [ -d "${ARCHIVE_PATH:-}" ] || exit 0
    bump_build
    bump_version minor
    ;;
build)
    bump_build
    ;;
patch | minor | major)
    bump_version "$1"
    ;;
set)
    case "${2:-}" in
    "" | *[!0-9.]* | .* | *. | *..*)
        echo "usage: $0 set 1.4" >&2
        exit 1
        ;;
    esac
    replace MARKETING_VERSION "$2"
    ;;
*)
    sed -n '2,11s/^# \{0,1\}//p' "$0" >&2
    exit 1
    ;;
esac

echo "Version $(current MARKETING_VERSION) ($(current CURRENT_PROJECT_VERSION))"
