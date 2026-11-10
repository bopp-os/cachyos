# Out-of-tree kernel module sources, shared by prefetch_extras.sh (which fetches them) and build_kernel_modules.sh
# (which builds them from what prefetch saved). Sourced, not executed.
#
# Two kinds of source, so no build ever takes whatever a third-party repository holds at that moment:
#
# KMOD_PACKAGES: modules CachyOS packages as -dkms. The source comes out of the signed package, so it is the version
# CachyOS chose, pinned by their PKGBUILD checksums and checked by pacman's signature verification. These update when
# CachyOS bumps the package; nothing to do here.
#
# KMOD_REPOS + KMOD_COMMITS: modules no distribution packages. Each is pinned to a full commit hash, which cannot be
# moved the way a branch or a tag can. To update one:
#   1. Pick a commit at least 14 days old (a compromised push is usually caught within that window).
#   2. Read the diff from the current pin to it on GitHub (.../compare/<old>...<new>).
#   3. Update the hash, the KMOD_VERSIONS label and the date comment together.
# Update only when there is a reason (new board support, a bug fix, a kernel API break).

declare -A KMOD_PACKAGES=(
    [xpadneo]="xpadneo-dkms"
    [zenergy]="zenergy-dkms-git"
)

declare -A KMOD_REPOS=(
    [nct6687d]="https://github.com/Fred78290/nct6687d.git"
    [it87]="https://github.com/frankcrawford/it87.git"
    # OpenGamingCollective fork of dlundqvist/xone without the wired driver, so wired pads stay on the in-tree xpad
    [xone]="https://github.com/OpenGamingCollective/xonedo.git"
)

declare -A KMOD_COMMITS=(
    [nct6687d]="ec1030ba7acc32b36723af0c7c9c9aead5e57b54"  # 2026-10-19, PR #223 (remove-ec-io-lock)
    [it87]="bd7a566c8a60fe0308d67e26761e16260368191a"      # 2026-10-02, PR #140 (fix-bridge)
    # 2026-03-15. Not the v0.5.7-ogc1 tag: that tag is older than the "remove wired support" commit.
    [xone]="982cbcb019ae4d2bee5ae69385223409ee555c88"
)

# Version string a module's build needs (xone fills its #VERSION# placeholder with it), in "git describe" form.
declare -A KMOD_VERSIONS=(
    [nct6687d]="git-ec1030b"
    [it87]="git-bd7a566"
    [xone]="v0.5.7-ogc1-11-g982cbcb"
)

# Fetches the pinned commit of repo module $1 into the new directory $2. Fails unless the checkout is that exact commit.
kmod_fetch_commit() {
    local name=$1 dest=$2
    local sha=${KMOD_COMMITS[$name]}
    git -c init.defaultBranch=pinned init --quiet "$dest" &&
        git -C "$dest" fetch --quiet --depth 1 "${KMOD_REPOS[$name]}" "$sha" &&
        git -C "$dest" -c advice.detachedHead=false checkout --quiet FETCH_HEAD &&
        [ "$(git -C "$dest" rev-parse HEAD)" = "$sha" ] || {
        echo "ERROR: could not fetch $name at the pinned commit $sha from ${KMOD_REPOS[$name]}" >&2
        return 1
    }
}
