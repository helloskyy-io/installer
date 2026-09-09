#!/usr/bin/env bash
#
# image-manager — public installer (stage 1 of 3)
#
# WHAT THIS IS. The first of three stages that stand up an image-manager
# instance. Its job is to get this repository onto a bare VM and hand off.
#
#   Stage 1  THIS FILE            bare VM  ->  source at /opt/skyy-net/image-manager
#   Stage 2  <repo>/bootstrap.sh  source   ->  k3s + Temporal + a worker image
#   Stage 3  Genesis (Temporal)   that     ->  Harbor, the public edge, the build path
#
# WHY IT LIVES IN A PUBLIC REPO. This script is what FETCHES image-manager, and
# image-manager is private. If this script lived there too, you would need the
# token at `curl` time — which means the token on a command line, which means the
# token in shell history. **Being public is what lets it ASK for the credential
# instead of being handed one**, and that is the whole reason for the split.
#
# WHY IT MAY NOT PULL AN IMAGE. image-manager is the tier every other product
# pulls its images FROM. Instance zero cannot be installed by pulling an image,
# because at that moment there is no registry. Source and packages only.
#
# IT ASSUMES A RENTED VM AND NOTHING ELSE. No hypervisor, no host agent, no
# platform underneath. We happen to run instance zero on MDC1 because we own
# that hardware, but this tier belongs to no ecosystem and installs the same way
# on a VPS from anyone.
#
#   NO QEMU-GUEST-AGENT, AND THAT IS A SECURITY RULING RATHER THAN A TRIM. A
#   guest agent is a channel FROM the hypervisor INTO the guest — it can execute
#   commands and read the filesystem. Installing one is defensible on a box we
#   own and manage; shipping it to an operator's VM is a back door we put there.
#   This tier is a product other people will run, so the installer must never
#   place one. If OUR instance wants an agent for OUR convenience, the MDC that
#   hosts it installs it — that is the hypervisor's business, not this product's.
#
# IT CONVERGES; IT DOES NOT SKIP. Every task asks "is the end state true?" and
# makes it true if not. It never asks "does the artifact exist?" and step over.
# The difference is not stylistic: a clone that died mid-transfer leaves a
# `.git` directory that passes an existence check and fails everything after it.
# Re-running this command is always correct, from any state.
#
# THE TOKEN, AND THE ONE QUESTION THAT DECIDES IT. A GitHub fine-grained PAT,
# read-only (`contents: read` + `metadata: read`), scoped to
# helloskyy-io/image-manager.
#
#   The operator is asked for it only when it is NEEDED, and need is decided by
#   ONE question that can be answered without a token: **is there a usable one
#   already in the k3s Secret?**
#
#       no k3s yet             -> needed -> prompt
#       k3s, no Secret         -> needed -> prompt
#       Secret, token rejected -> needed -> prompt   <- the 366-day expiry case
#       Secret, token works    -> not needed, never prompt
#
#   PRESENCE IS NOT VALIDITY, and that distinction is load-bearing. A
#   fine-grained PAT expires after at most 366 days. On that day the Secret
#   still exists and the token in it is dead — a presence check says "skip" and
#   the install proceeds with a credential GitHub rejects, failing later
#   somewhere unrelated. Only asking GitHub catches it.
#
#   IT NEVER COMES TO REST. Read from the environment or from the terminal,
#   held in a shell variable, passed to the child in its environment. Never
#   written to a file, never in a remote URL, never in `.git/config`, never on a
#   command line where `ps` can read it, and never echoed.
#
# USAGE
#   curl -fsSL https://raw.githubusercontent.com/helloskyy-io/installer/main/image-manager/bootstrap.sh | sudo bash
#
#   It prompts for the token if it needs one. **Nothing is typed on the command
#   line, so nothing lands in shell history.**
#
#   For an unattended re-run, `IMAGE_MANAGER_PAT` in the environment
#   short-circuits the PROMPT — never the check — and needs `sudo -E`.

set -euo pipefail

BASE_DIR="${BASE_DIR:-/opt/skyy-net}"
GROUP_NAME="${GROUP_NAME:-skyy-net}"
REPO_OWNER="${REPO_OWNER:-helloskyy-io}"
REPO_NAME="${REPO_NAME:-image-manager}"
REPO_DIR="${BASE_DIR}/${REPO_NAME}"
REPO_REF="${REPO_REF:-main}"
GIT_USER_NAME="${GIT_USER_NAME:-Skyy Net}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-info@helloskyy.io}"

# Where stage 2 puts the durable copy. Stage 1 only READS this, to decide
# whether it must ask. Kept in sync with bootstrap.sh by name, deliberately —
# stage 1 cannot import anything from a repo it has not cloned yet.
PAT_SECRET_NS="${PAT_SECRET_NS:-image-manager}"
PAT_SECRET_NAME="${PAT_SECRET_NAME:-repo-read-pat}"
PAT_SECRET_KEY="${PAT_SECRET_KEY:-token}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

PAT=""
ASKPASS_DIR=""
cleanup() {
    PAT=""
    [[ -n "$ASKPASS_DIR" && -d "$ASKPASS_DIR" ]] && rm -rf "$ASKPASS_DIR"
    return 0
}
trap cleanup EXIT

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Run as root: curl -fsSL <url> | sudo bash"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# The credential decision
# ---------------------------------------------------------------------------

# Reads the token out of the k3s Secret if one is there. Empty on any failure —
# no k3s, no namespace, no Secret, no key. Every one of those means "we do not
# have a token", which is the only thing the caller needs to know.
read_pat_from_cluster() {
    command -v kubectl >/dev/null 2>&1 || return 0
    [[ -r /etc/rancher/k3s/k3s.yaml ]] || return 0
    KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n "$PAT_SECRET_NS" \
        get secret "$PAT_SECRET_NAME" -o "jsonpath={.data.${PAT_SECRET_KEY}}" 2>/dev/null \
        | base64 -d 2>/dev/null || true
}

# PRESENCE IS NOT VALIDITY. Asks GitHub whether this token can actually read the
# repository. 200 means yes. Anything else — expired, revoked, unapproved,
# wrong scope — means we need a new one, and the operator finds out here rather
# than three steps later.
pat_is_usable() {
    local token="$1" code cfgdir
    [[ -n "$token" ]] || return 1

    # THE TOKEN GOES IN A CONFIG FILE, NOT ON THE COMMAND LINE. `-H "Authorization:
    # Bearer $token"` puts the credential in /proc/<pid>/cmdline, where any local
    # process can read it for as long as curl runs -- the surface Credential
    # Lifecycle §2.6 invariant 2 forbids BY NAME, and the one requirement 6 of
    # this phase is written about. `--config` is read by curl and by nothing else.
    #
    # THIS WAS A REAL LEAK, NOT A HYPOTHETICAL ONE. It shipped, ran on instance
    # zero, and was found on 2026-09-09 by the first run of
    # test/canary_credential_surfaces.sh -- which is the entire argument for
    # having written that test.
    cfgdir="$(mktemp -d)" || return 1
    chmod 700 "$cfgdir"
    printf 'header = "Authorization: Bearer %s"\n' "$token" > "${cfgdir}/curlrc"
    chmod 600 "${cfgdir}/curlrc"

    code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 15 \
        --config "${cfgdir}/curlrc" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}" 2>/dev/null || echo "000")"

    # Shredded on every path out, including the failure paths above this line
    # having already returned -- which is why the directory is created late.
    rm -rf "$cfgdir"
    [[ "$code" == "200" ]]
}

# THE ONE QUESTION. Sets PAT, or exits. Order is cheapest-first: an env var
# costs nothing to check, the cluster costs a kubectl call, and only if both
# come up empty is a human interrupted.
resolve_pat() {
    if [[ -n "${IMAGE_MANAGER_PAT:-}" ]]; then
        log_info "Token supplied in the environment; validating..."
        if pat_is_usable "$IMAGE_MANAGER_PAT"; then
            PAT="$IMAGE_MANAGER_PAT"
            log_info "Token valid for ${REPO_OWNER}/${REPO_NAME}"
            return 0
        fi
        log_error "IMAGE_MANAGER_PAT is set but cannot read ${REPO_OWNER}/${REPO_NAME}."
        log_error "  Expired, revoked, awaiting org approval, or missing Contents:Read."
        exit 1
    fi

    local existing
    existing="$(read_pat_from_cluster)"
    if [[ -n "$existing" ]]; then
        log_info "Found a token in the k3s Secret; validating..."
        if pat_is_usable "$existing"; then
            PAT="$existing"
            log_info "Stored token is valid — not asking you for one"
            return 0
        fi
        log_warn "The stored token is present but NO LONGER VALID."
        log_warn "  Fine-grained tokens expire after at most 366 days; this is the usual cause."
        log_warn "  A new one is needed. Stage 2 will replace the stored copy."
    fi

    # READ FROM THE TERMINAL, NOT STDIN. Under `curl | bash`, stdin IS the
    # script — a plain `read` would consume the next lines of this file and
    # execute nothing. /dev/tty is the operator's keyboard regardless of how
    # the script arrived.
    if [[ ! -r /dev/tty ]]; then
        log_error "A token is needed and there is no terminal to ask on."
        log_error "  Re-run interactively, or set IMAGE_MANAGER_PAT and use 'sudo -E'."
        exit 1
    fi

    echo "" >&2
    log_info "A GitHub token is needed to clone ${REPO_OWNER}/${REPO_NAME}."
    log_info "  Fine-grained, READ-ONLY, scoped to that one repository:"
    log_info "    Contents: Read-only   (Metadata sets itself)"
    log_info "  See image-manager/README.md in this installer repo for the exact steps."
    echo "" >&2
    printf "Paste the token (input hidden): " >&2
    read -rs PAT < /dev/tty
    echo "" >&2

    if [[ -z "$PAT" ]]; then
        log_error "No token entered."
        exit 1
    fi
    if ! pat_is_usable "$PAT"; then
        log_error "That token cannot read ${REPO_OWNER}/${REPO_NAME}."
        log_error "  Check: org approval, Contents:Read, and that the repo is selected."
        exit 1
    fi
    log_info "Token valid for ${REPO_OWNER}/${REPO_NAME}"
}

# ---------------------------------------------------------------------------
# Converging tasks — each asks "is the end state true?", never "does it exist?"
# ---------------------------------------------------------------------------

ensure_acl() {
    command -v setfacl >/dev/null 2>&1 && return 0
    log_info "Installing 'acl' (provides setfacl)..."
    apt-get update -qq
    apt-get install -y acl >/dev/null || { log_error "Failed to install 'acl'"; return 1; }
}

ensure_git() {
    if ! command -v git >/dev/null 2>&1; then
        log_info "Installing git..."
        apt-get update -qq
        apt-get install -y git >/dev/null || { log_error "Failed to install git"; return 1; }
    fi
    git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true
    git config --global user.name  "$GIT_USER_NAME"  2>/dev/null || true
    git config --global user.email "$GIT_USER_EMAIL" 2>/dev/null || true
    log_info "git ready: $(git --version)"
}

# Four independent end-states, so a box where any one of them is wrong gets
# repaired rather than stepped over.
ensure_base_dir_and_group() {
    ensure_acl
    [[ -d "$BASE_DIR" ]] || { log_info "Creating $BASE_DIR"; mkdir -p "$BASE_DIR"; }
    getent group "$GROUP_NAME" >/dev/null 2>&1 || { log_info "Creating group '$GROUP_NAME'"; groupadd "$GROUP_NAME"; }

    local operator="${SUDO_USER:-}"
    if [[ -n "$operator" ]] && id "$operator" >/dev/null 2>&1; then
        if ! id -nG "$operator" | tr ' ' '\n' | grep -qx "$GROUP_NAME"; then
            usermod -aG "$GROUP_NAME" "$operator"
            log_info "Added '$operator' to '$GROUP_NAME' (new group applies at next login)"
        fi
    else
        log_warn "No SUDO_USER — add your operator account to '$GROUP_NAME' by hand"
    fi

    chgrp -R "$GROUP_NAME" "$BASE_DIR" 2>/dev/null || true
    chmod -R g+rwX "$BASE_DIR" 2>/dev/null || true
    chmod g+s "$BASE_DIR"
    setfacl -d -m g::rwx "$BASE_DIR" 2>/dev/null || log_warn "Could not set default ACL on $BASE_DIR"
    log_info "$BASE_DIR ready, group '$GROUP_NAME'"
}

# THE FOUR SURFACES THE TOKEN MUST NOT REACH, and how each is closed:
#   argv        -> GIT_ASKPASS supplies it; never an argument
#   remote URL  -> the URL written to .git/config carries no credential
#   .git/config -> follows from the above, and is ASSERTED below
#   cred store  -> `-c credential.helper=` neutralises any inherited helper
# Same shape as skyy-command's _pat_auth.py, in shell, because stage 1 runs
# before any of that code is on the box.
# The askpass helper, created once so BOTH fetch and clone can use it. The
# token's VALUE is never in the file — only a reference to the environment.
make_askpass() {
    [[ -n "$ASKPASS_DIR" ]] && return 0
    ASKPASS_DIR="$(mktemp -d)"; chmod 700 "$ASKPASS_DIR"
    cat > "${ASKPASS_DIR}/askpass.sh" <<'ASKPASS'
#!/usr/bin/env bash
case "$1" in
    Username*) echo "x-access-token" ;;
    *)         echo "${IMAGE_MANAGER_PAT_INTERNAL}" ;;
esac
ASKPASS
    chmod 700 "${ASKPASS_DIR}/askpass.sh"
}

# Runs git with the token supplied through GIT_ASKPASS. THE FOUR SURFACES THE
# TOKEN MUST NOT REACH, and how each is closed:
#   argv        -> GIT_ASKPASS supplies it; never an argument
#   remote URL  -> the URL in .git/config carries no credential
#   .git/config -> follows from the above, and is ASSERTED below
#   cred store  -> `-c credential.helper=` neutralises any inherited helper
git_with_token() {
    make_askpass
    IMAGE_MANAGER_PAT_INTERNAL="$PAT" GIT_ASKPASS="${ASKPASS_DIR}/askpass.sh" \
        GIT_TERMINAL_PROMPT=0 git -c credential.helper= "$@"
}

# PRESENT IS NOT CURRENT, and that is the whole point of this function.
#
# An earlier version stopped at "is this a valid git repository?" and returned.
# That is the same defect as checking a Secret exists without asking whether the
# token in it still works: it tests the wrong property. A checkout made before
# the last push is a valid repository AND the wrong code, so the install
# proceeded against a stale tree and failed on a file that had been pushed
# hours earlier.
#
# The end state is "the repository is present AND at the expected ref", so that
# is what this converges to.
ensure_repo_cloned() {
    if ! git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        if [[ -e "$REPO_DIR" ]]; then
            log_warn "$REPO_DIR exists but is not a valid git repository — removing and re-cloning"
            rm -rf "$REPO_DIR"
        fi
        log_info "Cloning ${REPO_OWNER}/${REPO_NAME} (${REPO_REF})..."
        if ! git_with_token clone --branch "$REPO_REF" \
             "https://github.com/${REPO_OWNER}/${REPO_NAME}.git" "$REPO_DIR"; then
            log_error "Clone failed despite a token that validated moments ago."
            log_error "  Network, or the branch '${REPO_REF}' does not exist."
            return 1
        fi
        assert_remote_is_clean
        fix_repo_ownership
        log_info "Clone complete"
        return 0
    fi

    log_info "Repository present — checking it is current..."
    assert_remote_is_clean

    if ! git_with_token -C "$REPO_DIR" fetch --quiet origin "$REPO_REF"; then
        log_warn "Could not reach the remote — continuing with the checkout as it stands"
        return 0
    fi

    local local_sha remote_sha
    local_sha="$(git -C "$REPO_DIR" rev-parse HEAD)"
    remote_sha="$(git -C "$REPO_DIR" rev-parse FETCH_HEAD)"

    if [[ "$local_sha" == "$remote_sha" ]]; then
        log_info "Already current at ${local_sha:0:8}"
        fix_repo_ownership
        return 0
    fi

    # NEVER DESTROY LOCAL WORK. This box is an install target and may also be
    # where someone is editing. A fast-forward is safe; anything else is the
    # operator's call, and a warning they can act on beats a reset they cannot
    # undo.
    if [[ -n "$(git -C "$REPO_DIR" status --porcelain)" ]]; then
        log_warn "Local changes present — NOT updating, and not discarding them."
        log_warn "  HEAD ${local_sha:0:8}, remote ${remote_sha:0:8}."
        log_warn "  Commit or stash them, then re-run."
        return 0
    fi

    if git -C "$REPO_DIR" merge-base --is-ancestor HEAD FETCH_HEAD 2>/dev/null; then
        log_info "Behind by $(git -C "$REPO_DIR" rev-list --count HEAD..FETCH_HEAD) commit(s) — fast-forwarding to ${remote_sha:0:8}"
        git -C "$REPO_DIR" merge --ff-only --quiet FETCH_HEAD
        fix_repo_ownership
        log_info "Now current at $(git -C "$REPO_DIR" rev-parse --short HEAD)"
    else
        log_warn "Local HEAD has diverged from ${REPO_REF} — NOT updating."
        log_warn "  HEAD ${local_sha:0:8}, remote ${remote_sha:0:8}. Resolve by hand, then re-run."
    fi
}

fix_repo_ownership() {
    chgrp -R "$GROUP_NAME" "$REPO_DIR" 2>/dev/null || true
    chmod -R g+rwX "$REPO_DIR" 2>/dev/null || true
}

# Asserted rather than assumed: a token in .git/config is exactly the durable
# copy this script exists to avoid, and it would outlive every later stage.
assert_remote_is_clean() {
    local origin
    origin="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || echo "")"
    if [[ "$origin" == *"@"* ]]; then
        log_error "Stored remote contains a credential — refusing to continue."
        exit 1
    fi
    log_info "Stored remote is credential-free"
}

# The token reaches stage 2 in its ENVIRONMENT — not a file, not an argument.
# Stage 2 is what writes the durable copy into a k3s Secret, once a cluster
# encrypted at rest exists to hold it.
hand_off_to_stage_2() {
    local next="${REPO_DIR}/bootstrap.sh"
    if [[ ! -f "$next" ]]; then
        log_error "Stage 2 not found at $next"
        log_error "  The clone succeeded, so this is a repo-layout change rather than an install failure."
        return 1
    fi
    chmod +x "$next"
    log_info "Handing off to stage 2: $next"
    echo ""
    IMAGE_MANAGER_PAT="$PAT" exec "$next"
}

main() {
    log_info "═══════════════════════════════════════════════════════════════"
    log_info "image-manager — public installer (stage 1 of 3)"
    log_info "═══════════════════════════════════════════════════════════════"
    echo ""
    check_root

    log_info "[1/4] deciding whether a token is needed..."; resolve_pat              ; echo ""
    log_info "[2/4] base directory and group..."          ; ensure_base_dir_and_group; echo ""
    log_info "[3/4] git..."                               ; ensure_git               ; echo ""
    log_info "[4/4] repository..."                        ; ensure_repo_cloned       ; echo ""
    hand_off_to_stage_2
}

main "$@"
