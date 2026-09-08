#!/usr/bin/env bash
#
# image-manager — public installer (Stage 1 of 3)
#
# WHAT THIS IS. The first of three stages that stand up an image-manager
# instance. Its entire job is to get this repository onto a bare VM and hand
# off. It installs nothing the tier runs on.
#
#   Stage 1  THIS FILE          bare VM  ->  source on disk
#   Stage 2  <repo>/bootstrap.sh  source  ->  k3s + Temporal + a worker image
#   Stage 3  Genesis (Temporal)   that    ->  Harbor, the edge, the build path
#
# WHY IT LIVES HERE AND NOT IN image-manager. This script is what FETCHES
# image-manager, so it must be reachable by a machine that does not have
# image-manager yet — a public URL, no credential. A stage-1 script inside the
# repository it clones is a circle.
#
# WHY IT MAY NOT PULL AN IMAGE. image-manager is the tier every other product
# pulls its images FROM. Instance zero therefore cannot be installed by pulling
# an image, because at that moment there is no registry to pull from. That
# asymmetry is the component's defining constraint, and this script is where it
# is first honoured: source and packages only, no artifact from this tier.
#
# WHAT IT DELIBERATELY DOES NOT DO, and each is a departure from its sibling
# `skyy-command/bootstrap.sh` rather than an oversight:
#
#   * NO Docker.  image-manager runs containerd only and builds daemonlessly
#     with host-side buildah. A Docker daemon on this box is forbidden outright,
#     so installing one here would have to be undone by stage 2.
#   * NO SSH deploy key, and NO `Host *-github` wildcard block.  A deploy key is
#     per-repository, which is why the sibling needs a keypair and an alias for
#     each repo it clones and a manual "paste this into GitHub, then press
#     ENTER" pause in the middle of an install. One fine-grained token replaces
#     the whole scheme, and this tier clones exactly ONE repository anyway.
#   * NO Helm.  Stage 2 installs it, because stage 2 is what uses it.
#   * NO manual pause.  Given the token, this runs start to finish unattended.
#
# THE TOKEN. A GitHub fine-grained personal access token, read-only
# (`contents: read` + `metadata: read`), scoped to helloskyy-io/image-manager.
#
#   IT IS HELD TRANSIENTLY AND NEVER COMES TO REST. It is read from the
#   environment, used for one clone, and gone when this process exits. It is
#   never written to a file, never placed in the remote URL, never left in
#   .git/config, and never passed on a command line where `ps` could read it —
#   git receives it through GIT_ASKPASS, which is the only mechanism here that
#   satisfies all four. The repository's Credential Lifecycle addendum requires
#   this; the same shape is why `git -c credential.helper=` appears below.
#
#   Stage 2 places the durable copy into a k3s Secret, once there is a cluster
#   encrypted at rest to hold it. Nothing durable exists at stage 1, which is
#   exactly why nothing durable is written here.
#
# USAGE
#   export IMAGE_MANAGER_PAT=github_pat_...
#   curl -fsSL https://raw.githubusercontent.com/helloskyy-io/installer/main/image-manager/bootstrap.sh | sudo -E bash
#
#   `sudo -E` matters: without it the token does not survive into this process.

set -euo pipefail

BASE_DIR="${BASE_DIR:-/opt/skyy-net}"
GROUP_NAME="${GROUP_NAME:-skyy-net}"
REPO_OWNER="${REPO_OWNER:-helloskyy-io}"
REPO_NAME="${REPO_NAME:-image-manager}"
REPO_DIR="${BASE_DIR}/${REPO_NAME}"
REPO_REF="${REPO_REF:-main}"
GIT_USER_NAME="${GIT_USER_NAME:-Skyy Net}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-info@helloskyy.io}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# The askpass helper is written to a mode-0700 file in a private temp dir and
# shredded on exit. It echoes an ENV VAR — the token's value is never in the
# file, so even mid-run the file discloses nothing.
ASKPASS_DIR=""
cleanup() {
    if [[ -n "$ASKPASS_DIR" && -d "$ASKPASS_DIR" ]]; then
        rm -rf "$ASKPASS_DIR"
    fi
}
trap cleanup EXIT

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use: sudo -E bash)"
        exit 1
    fi
}

# The token is the ONE thing this script cannot proceed without, and the ONE
# thing it must not persist. Checked before any side effect, so a missing token
# costs an error message rather than a half-installed box.
verify_token_present() {
    if [[ -z "${IMAGE_MANAGER_PAT:-}" ]]; then
        log_error "IMAGE_MANAGER_PAT is not set."
        log_error ""
        log_error "  A fine-grained GitHub token, READ-ONLY, scoped to"
        log_error "  ${REPO_OWNER}/${REPO_NAME}: contents:read + metadata:read."
        log_error ""
        log_error "  export IMAGE_MANAGER_PAT=github_pat_..."
        log_error "  ...then re-run with 'sudo -E' so it survives into this process."
        exit 1
    fi
    log_info "Repo-read token present (value never logged, never written to disk)"
}

# qemu-guest-agent lets the hypervisor see and quiesce this VM. It is a host
# prerequisite rather than an image-manager one, which is why it comes first.
ensure_qemu_guest_agent() {
    if systemctl is-active --quiet qemu-guest-agent 2>/dev/null; then
        log_info "qemu-guest-agent already running"
        return 0
    fi
    log_info "Installing qemu-guest-agent..."
    apt-get update -qq
    apt-get install -y qemu-guest-agent || {
        log_warn "qemu-guest-agent install failed — continuing (not fatal to the install)"
        return 0
    }
    systemctl enable --now qemu-guest-agent || log_warn "Could not start qemu-guest-agent"
}

# Ported from skyy-command/bootstrap.sh Task 0, which had this right. The `acl`
# dependency is real: setfacl is POSIX-standard and still absent from a fresh
# Ubuntu Server, and the default ACL is what lets the operator and later
# processes share the tree without a chmod race.
setup_folder_and_group() {
    if ! command -v setfacl >/dev/null 2>&1; then
        log_info "Installing 'acl' (provides setfacl)..."
        apt-get update -qq
        apt-get install -y acl || { log_error "Failed to install 'acl'"; return 1; }
    fi

    if [[ ! -d "$BASE_DIR" ]]; then
        log_info "Creating $BASE_DIR"
        mkdir -p "$BASE_DIR"
    fi

    if ! getent group "$GROUP_NAME" >/dev/null 2>&1; then
        log_info "Creating group '$GROUP_NAME'"
        groupadd "$GROUP_NAME"
    fi

    # SUDO_USER is the human who invoked sudo; root has no business owning the
    # tree they will be editing.
    local operator="${SUDO_USER:-}"
    if [[ -n "$operator" ]] && id "$operator" >/dev/null 2>&1; then
        usermod -aG "$GROUP_NAME" "$operator"
        log_info "Added '$operator' to '$GROUP_NAME'"
    else
        log_warn "No SUDO_USER detected — add your operator account to '$GROUP_NAME' by hand"
    fi

    chgrp -R "$GROUP_NAME" "$BASE_DIR"
    chmod -R g+rwX "$BASE_DIR"
    chmod g+s "$BASE_DIR"
    setfacl -d -m g::rwx "$BASE_DIR" || log_warn "Could not set default ACL on $BASE_DIR"
    log_info "Folder structure and group ready at $BASE_DIR"
}

install_git() {
    if ! command -v git >/dev/null 2>&1; then
        log_info "Installing git..."
        apt-get update -qq
        apt-get install -y git || { log_error "Failed to install git"; return 1; }
    else
        log_info "git already installed: $(git --version)"
    fi
    git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true
    git config --global user.name  "$GIT_USER_NAME"  2>/dev/null || true
    git config --global user.email "$GIT_USER_EMAIL" 2>/dev/null || true
}

# THE CLONE, AND THE FOUR SURFACES THE TOKEN MUST NOT REACH.
#
#   argv          -> GIT_ASKPASS supplies it; it is never an argument
#   the remote    -> the URL committed to .git/config carries no credential
#   .git/config   -> follows from the above
#   a credential  -> `-c credential.helper=` neutralises any inherited helper,
#   store            so nothing is cached to disk
#
# This is the shape `skyy-command/lib/temporal/activities/git/_pat_auth.py`
# arrived at for the same problem. Reproduced here in shell because stage 1 runs
# before any of that code is on the box.
clone_repo() {
    if [[ -d "$REPO_DIR/.git" ]]; then
        log_info "$REPO_DIR already a git repo — leaving it alone (idempotent)"
        return 0
    fi

    ASKPASS_DIR="$(mktemp -d)"
    chmod 700 "$ASKPASS_DIR"
    local askpass="${ASKPASS_DIR}/askpass.sh"
    cat > "$askpass" <<'ASKPASS'
#!/usr/bin/env bash
# git asks for a username first, then a password. x-access-token is GitHub's
# convention for token auth; the token itself comes from the environment.
case "$1" in
    Username*) echo "x-access-token" ;;
    *)         echo "${IMAGE_MANAGER_PAT}" ;;
esac
ASKPASS
    chmod 700 "$askpass"

    log_info "Cloning ${REPO_OWNER}/${REPO_NAME} (${REPO_REF}) into $REPO_DIR..."
    if ! GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 \
         git -c credential.helper= \
             clone --branch "$REPO_REF" \
             "https://github.com/${REPO_OWNER}/${REPO_NAME}.git" "$REPO_DIR"; then
        log_error "Clone failed."
        log_error "  Most likely: the token cannot read ${REPO_OWNER}/${REPO_NAME},"
        log_error "  or the organisation has not approved fine-grained tokens."
        return 1
    fi

    # The stored remote must be credential-free. Asserted rather than assumed:
    # a token in .git/config is exactly the durable copy this script exists to
    # avoid, and it would survive every later stage.
    local origin
    origin="$(git -C "$REPO_DIR" remote get-url origin)"
    if [[ "$origin" == *"@"* ]]; then
        log_error "Stored remote contains a credential — refusing to continue."
        log_error "  $origin"
        return 1
    fi

    chgrp -R "$GROUP_NAME" "$REPO_DIR"
    chmod -R g+rwX "$REPO_DIR"
    log_info "Clone complete; stored remote is credential-free"
}

# Stage 2 lives in the repo we just cloned. Named by path rather than searched
# for: the sibling installer hands off to a path that moved in April 2026 and
# fails on every fresh install to this day, so this checks before it execs.
launch_bootstrap() {
    local next="${REPO_DIR}/bootstrap.sh"
    if [[ ! -f "$next" ]]; then
        log_error "Stage 2 not found at $next"
        log_error "  The clone succeeded, so this is a repo-layout change rather than an install failure."
        return 1
    fi
    chmod +x "$next"
    log_info "Handing off to stage 2: $next"
    echo ""
    exec "$next"
}

main() {
    log_info "═══════════════════════════════════════════════════════════════"
    log_info "image-manager — public installer (stage 1 of 3)"
    log_info "═══════════════════════════════════════════════════════════════"
    echo ""

    check_root
    verify_token_present
    echo ""

    log_info "[1/5] qemu-guest-agent..."          ; ensure_qemu_guest_agent ; echo ""
    log_info "[2/5] folder structure and group..." ; setup_folder_and_group  ; echo ""
    log_info "[3/5] git..."                        ; install_git            ; echo ""
    log_info "[4/5] clone ${REPO_NAME}..."         ; clone_repo             ; echo ""
    log_info "[5/5] hand off to stage 2..."
    launch_bootstrap
}

main "$@"
