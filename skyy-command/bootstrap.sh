#!/bin/bash
#
# Skyy-Command Public Installer Script
#
# This script is the public entry point for installing the Skyy-Command platform.
# It can be downloaded via curl and sets up the initial environment, then delegates
# to the private bootstrap script in the skyy-command repository.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/helloskyy-io/installer/main/skyy-command/bootstrap.sh | sudo bash
#
#   It prompts for the MDC's READ token if it needs one — a GitHub fine-grained
#   PAT, read-only, covering the repositories it clones; the mint is the runbook's
#   (mdc-master-planning/guide/github_credentials.md). Nothing is typed on the
#   command line, so nothing lands in shell history. For an unattended re-run,
#   GITHUB_READ_PAT in the environment short-circuits the PROMPT — never the
#   check — and needs `sudo -E`.
#
# Target state: "skyy-command and mdc-ansible-collections are cloned and the
# private bootstrap script is ready to run"
#
# THE TOKEN NEVER COMES TO REST. Read from the environment or the terminal, held
# in a shell variable, handed to git through GIT_ASKPASS and to curl through a
# config file on tmpfs that dies with its subshell. Never in a remote URL, never
# in .git/config, never on a command line, never echoed. It is needed for the
# clones and for nothing after them, so it is cleared before the private
# bootstrap is launched. Carrying it across to the cluster is the private
# bootstrap's, once a cluster exists to hold it (The Token at the Floor).

set -euo pipefail

# Configuration

# Base directory for all Skyy-Net repositories
BASE_DIR="${BASE_DIR:-/opt/skyy-net}"

# Skyy-Command repository directory - where the skyy-command repo will be cloned
MDC_REPO_DIR="${MDC_REPO_DIR:-$BASE_DIR/skyy-command}"

# The GitHub account the platform is distributed from, and the two repositories
# this installer clones from it: skyy-command, and mdc-ansible-collections
# beside it — the private bootstrap's worker-image bake reads the collections
# from that clone and refuses to start without it.
GITHUB_OWNER="${GITHUB_OWNER:-helloskyy-io}"
SKYY_COMMAND_REPO_NAME="${SKYY_COMMAND_REPO_NAME:-Skyy-Command}"
COLLECTIONS_REPO_NAME="${COLLECTIONS_REPO_NAME:-mdc-ansible-collections}"
COLLECTIONS_REPO_DIR="${COLLECTIONS_REPO_DIR:-$BASE_DIR/mdc-ansible-collections}"

# User group name for collaborative development access
GROUP_NAME="${GROUP_NAME:-skyy-net}"

# Development user to add to the group (for SSH access via IDE)
#
# Priority: explicit $DEV_USER override → $SUDO_USER (the operator who ran
# `sudo bash`) → fallback "puma" (preserves historical behavior for
# direct-as-root invocations where $SUDO_USER is unset).
#
# Why auto-detect: every fresh-MDC stand-up needs the operator wired into
# the skyy-net group and POSIX ACLs. Hardcoding "puma" made that step fail
# for anyone else, and manually exporting DEV_USER is a friction point we
# kept forgetting.
DEV_USER="${DEV_USER:-${SUDO_USER:-puma}}"

# Where the platform keeps the READ token's delivery copy once a cluster exists
# (GitHub Automation Standard §1.4). The installer only READS this, to decide
# whether it must ask. Kept in sync with the ingest script by name, deliberately
# — the installer cannot import anything from a repo it has not cloned yet.
PAT_SECRET_NS="${PAT_SECRET_NS:-skyy-command}"
PAT_SECRET_NAME="${PAT_SECRET_NAME:-github-read}"
PAT_SECRET_KEY="${PAT_SECRET_KEY:-pat}"

# Git identity configuration (for root user)
GIT_USER_NAME="${GIT_USER_NAME:-SkyyCommand Platform}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-info@helloskyy.io}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# The token, and the askpass helper that hands it to git. Both die with the
# script — on every exit path, success and failure alike.
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
        log_error "This script must be run as root"
        exit 1
    fi
}

# Task 0: Create folder structure and user group
setup_folder_and_group() {
    log_info "Setting up folder structure and user group..."

    # Ensure the `acl` package is installed — setfacl is required below for
    # default POSIX ACLs on $BASE_DIR. `setfacl` is NOT installed on a fresh
    # Ubuntu Server by default despite being a POSIX-standard tool.
    if ! command -v setfacl >/dev/null 2>&1; then
        log_info "Installing 'acl' package (provides setfacl for POSIX ACLs)..."
        apt-get update -qq
        apt-get install -y acl || {
            log_error "Failed to install 'acl' package"
            return 1
        }
        log_info "'acl' package installed successfully"
    else
        log_info "'acl' package already installed (setfacl found): $(command -v setfacl)"
    fi

    # Create base directory if it doesn't exist
    if [[ ! -d "$BASE_DIR" ]]; then
        log_info "Creating base directory: $BASE_DIR"
        mkdir -p "$BASE_DIR"
    else
        log_info "Base directory already exists: $BASE_DIR"
    fi
    
    # Create group if it doesn't exist (using -f flag for idempotency)
    if getent group "$GROUP_NAME" > /dev/null 2>&1; then
        log_info "Group '$GROUP_NAME' already exists"
    else
        log_info "Creating group: $GROUP_NAME"
        groupadd -f "$GROUP_NAME" || {
            log_error "Failed to create group: $GROUP_NAME"
            return 1
        }
        log_info "Group '$GROUP_NAME' created successfully"
    fi
    
    # Add dev user to group if user exists
    if id "$DEV_USER" &>/dev/null; then
        if groups "$DEV_USER" | grep -q "\b$GROUP_NAME\b"; then
            log_info "User '$DEV_USER' is already in group '$GROUP_NAME'"
        else
            log_info "Adding user '$DEV_USER' to group '$GROUP_NAME'"
            usermod -aG "$GROUP_NAME" "$DEV_USER" || {
                log_error "Failed to add user '$DEV_USER' to group '$GROUP_NAME'"
                return 1
            }
            log_info "User '$DEV_USER' added to group '$GROUP_NAME'"
            log_warn "User '$DEV_USER' may need to log out and back in for group changes to take effect"
        fi
    else
        log_warn "User '$DEV_USER' does not exist, skipping group assignment"
    fi
    
    # Check if ownership and directory permissions are already correct (idempotency check)
    local needs_ownership=false
    local needs_dir_perms=false
    
    # Check ownership on base directory
    local current_owner=$(stat -c "%U:%G" "$BASE_DIR" 2>/dev/null)
    if [[ "$current_owner" != "root:$GROUP_NAME" ]]; then
        needs_ownership=true
        log_info "Ownership needs update: current=$current_owner, expected=root:$GROUP_NAME"
    fi
    
    # Check directory permissions on base directory
    local base_dir_perms=$(stat -c "%a" "$BASE_DIR" 2>/dev/null)
    if [[ "$base_dir_perms" != "2775" ]]; then
        needs_dir_perms=true
        log_info "Base directory permissions need update: current=$base_dir_perms, expected=2775"
    fi
    
    # Set ownership if needed (idempotent - only changes if wrong)
    if [[ "$needs_ownership" == "true" ]]; then
        log_info "Setting ownership to root:$GROUP_NAME"
        chown -R root:"$GROUP_NAME" "$BASE_DIR" || {
            log_error "Failed to set ownership"
            return 1
        }
    else
        log_info "Ownership already correct (root:$GROUP_NAME), skipping"
    fi
    
    # Set directory permissions if needed (idempotent - only changes if wrong)
    if [[ "$needs_dir_perms" == "true" ]]; then
        log_info "Setting directory permissions to 2775 (setgid + group writable)"
        find "$BASE_DIR" -type d -exec chmod 2775 {} \; || {
            log_error "Failed to set directory permissions"
            return 1
        }
    else
        log_info "Directory permissions already correct (2775), skipping"
    fi

    # POSIX default ACLs — apply group write regardless of root's umask.
    #
    # Why: setgid on directories (2775 above) only controls group OWNERSHIP
    # inheritance for new files. It does NOT control permission BITS. Root
    # processes (migration scripts, Ansible, Genesis activities) create files
    # with umask 022, which means new files land with mode 644 — owner rw,
    # group READ ONLY. The setgid bit gives those files the right group
    # (skyy-net), but members of the group still can't write them, because
    # the group-write bit was never set.
    #
    # This bit us on 2026-04-12 during the Phase 1a migration: Ansible-created
    # files inherited group=skyy-net but mode=644, and puma (in the skyy-net
    # group) couldn't edit them via the IDE. The fix is POSIX default ACLs,
    # which override the umask for the specified group.
    #
    # Two setfacl calls:
    #   -m  (modify)   — applies the ACL to files that exist RIGHT NOW
    #   -d -m (default) — sets a default ACL on directories so that any file
    #                     created under them in the future inherits the ACL
    #                     automatically, regardless of what umask the creating
    #                     process uses
    #
    # The default ACL also automatically extends to any new subtree cloned
    # under $BASE_DIR later (e.g. `git clone` of a new repo), so this is a
    # one-time setup that never needs re-application.
    #
    # Idempotency: setfacl is inherently idempotent — running it a second
    # time with the same rule is a no-op. We check for the marker in
    # `getfacl` output to skip noisy logs on re-runs.
    local needs_acls=true
    if getfacl -p "$BASE_DIR" 2>/dev/null | grep -q "^default:group:$GROUP_NAME:rwx"; then
        needs_acls=false
        log_info "POSIX default ACL already set on $BASE_DIR for group '$GROUP_NAME', skipping"
    fi

    if [[ "$needs_acls" == "true" ]]; then
        log_info "Applying POSIX ACLs to $BASE_DIR for group '$GROUP_NAME'..."

        # Apply to existing files and directories
        setfacl -R -m "g:$GROUP_NAME:rwx" "$BASE_DIR" || {
            log_error "Failed to apply existing-file ACL to $BASE_DIR"
            return 1
        }
        log_info "  Applied existing-file ACL: g:$GROUP_NAME:rwx"

        # Set default ACL so future files inherit group write regardless of umask
        setfacl -R -d -m "g:$GROUP_NAME:rwx" "$BASE_DIR" || {
            log_error "Failed to apply default ACL to $BASE_DIR"
            return 1
        }
        log_info "  Applied default ACL:       g:$GROUP_NAME:rwx (new files inherit this)"
    fi

    log_info "Folder structure and group setup completed successfully"
    log_info "  Directory: $BASE_DIR"
    log_info "  Owner: root"
    log_info "  Group: $GROUP_NAME"
    log_info "  Directory permissions: 2775 (setgid enabled - new files inherit group)"
    log_info "  POSIX default ACL: g:$GROUP_NAME:rwx (new files are group-writable)"
}

# Task 2: Install Docker + Compose
install_docker() {
    log_info "Checking Docker installation..."
    
    if command -v docker &> /dev/null; then
        log_info "Docker is already installed: $(docker --version)"
    else
        log_info "Installing Docker using official repository method..."
        
        # Update package index
        apt-get update
        
        # Install prerequisites
        apt-get install -y \
            ca-certificates \
            curl \
            gnupg \
            lsb-release
        
        # Add Docker's official GPG key (modern method, avoids legacy key issues)
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        
        # Detect Ubuntu version and set up repository
        . /etc/os-release
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
          ${UBUNTU_CODENAME:-$(lsb_release -cs)} stable" | \
          tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        # Update package index with Docker repository
        apt-get update
        
        # Install Docker Engine, CLI, and containerd
        apt-get install -y \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin
        
        # Enable and start Docker service
        systemctl enable docker
        systemctl start docker
        
        # Verify installation
        if docker --version &> /dev/null; then
            log_info "Docker installed successfully: $(docker --version)"
        else
            log_error "Docker installation failed verification"
            return 1
        fi
    fi
    
    # Verify Docker Compose (v2 plugin)
    if docker compose version &> /dev/null; then
        log_info "Docker Compose is already available: $(docker compose version)"
    else
        log_warn "Docker Compose plugin not found, attempting to install..."
        apt-get update
        apt-get install -y docker-compose-plugin

        if docker compose version &> /dev/null; then
            log_info "Docker Compose installed successfully: $(docker compose version)"
        else
            log_error "Docker Compose installation failed"
            return 1
        fi
    fi

    # Add operator to the docker group.
    #
    # Why: operators run `docker build` against worker Dockerfiles during the
    # transitional period before Harbor lands (Sprint 2-5). Per the [Worker
    # Deployment Standard §4.4], images are built on the control-plane VM and
    # imported into K3s containerd via `k3s ctr images import` until Harbor
    # provides a registry. After Harbor, local image builds remain useful for
    # development iteration (Dockerfile changes, debugging). Without docker
    # group membership, every `docker` invocation requires sudo — friction
    # that compounds across iterations.
    #
    # Security note: docker group membership is effectively root (any member
    # can `docker run -v /:/host` and own the host). The operator already has
    # sudo, so adding docker group does NOT expand their privilege — it just
    # removes the sudo keystroke for the docker workflow.
    if id "$DEV_USER" &>/dev/null; then
        if groups "$DEV_USER" | grep -q "\bdocker\b"; then
            log_info "User '$DEV_USER' is already in group 'docker'"
        else
            log_info "Adding user '$DEV_USER' to group 'docker'"
            usermod -aG docker "$DEV_USER" || {
                log_error "Failed to add user '$DEV_USER' to group 'docker'"
                return 1
            }
            log_info "User '$DEV_USER' added to group 'docker'"
            log_warn "User '$DEV_USER' may need to log out and back in (or run 'newgrp docker') for group changes to take effect"
        fi
    else
        log_warn "User '$DEV_USER' does not exist, skipping docker group assignment"
    fi
}

# Task 3: Install Helm
#
# Why this is here:
#   The private bootstrap script
#   (skyy-command/lib/temporal/scripts/bootstrap/bootstrap.sh)
#   requires `helm` on PATH for the chart-rendering pipeline after the
#   Phase 1c A4 refactor (skyy-command PR #29). A fresh VM without helm
#   hits a clear error downstream, but provisioning helm proactively is
#   a cleaner onboarding experience.
#
# Install method: the official get-helm-3 script, downloaded to a
# tempfile first (never piped straight into bash). Matches the security
# posture of the Docker install above — the downloaded script is
# on-disk and auditable if the install fails.
install_helm() {
    log_info "Checking helm installation..."

    if command -v helm &> /dev/null; then
        log_info "helm already installed: $(helm version --short)"
        return 0
    fi

    log_info "Installing helm via official get-helm-3 script..."

    # Use mktemp to avoid a predictable-path race on /tmp — another
    # process could race to replace a fixed-path tempfile between the
    # curl write and the execute, and since we run as root, that's a
    # privilege-escalation vector. mktemp gives us a unique, unpredictable
    # path with 0600 perms out of the box.
    local installer_script
    installer_script=$(mktemp /tmp/get-helm-3-XXXXXX.sh) || {
        log_error "Failed to create tempfile for helm installer"
        return 1
    }
    if ! curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
            -o "$installer_script"; then
        log_error "Failed to download helm install script"
        rm -f "$installer_script"
        return 1
    fi
    chmod 700 "$installer_script"

    if ! "$installer_script"; then
        log_error "helm install script failed"
        rm -f "$installer_script"
        return 1
    fi
    rm -f "$installer_script"

    # Verify helm actually ended up on PATH — if the install script
    # "succeeded" but helm isn't callable, downstream Phase 2 bootstrap
    # will fail. Fail loudly here instead.
    if ! command -v helm &> /dev/null; then
        log_error "helm install script completed but 'helm' is not on PATH"
        return 1
    fi

    log_info "helm installed: $(helm version --short)"
}

# Task 4: Install git and configure identity
install_git() {
    log_info "Checking git installation..."
    
    if command -v git &> /dev/null; then
        log_info "Git is already installed: $(git --version)"
    else
        log_info "Installing git..."
        apt-get update
        apt-get install -y git
        log_info "Git installed successfully"
    fi
    
    # Configure git identity for root user (idempotent)
    log_info "Configuring git identity for root user..."
    
    # Check if git user.name is already configured
    local current_name=$(git config --global user.name 2>/dev/null || echo "")
    if [[ "$current_name" == "$GIT_USER_NAME" ]]; then
        log_info "Git user.name already configured: $GIT_USER_NAME"
    else
        log_info "Setting git user.name to: $GIT_USER_NAME"
        git config --global user.name "$GIT_USER_NAME" || {
            log_error "Failed to set git user.name"
            return 1
        }
    fi
    
    # Check if git user.email is already configured
    local current_email=$(git config --global user.email 2>/dev/null || echo "")
    if [[ "$current_email" == "$GIT_USER_EMAIL" ]]; then
        log_info "Git user.email already configured: $GIT_USER_EMAIL"
    else
        log_info "Setting git user.email to: $GIT_USER_EMAIL"
        git config --global user.email "$GIT_USER_EMAIL" || {
            log_error "Failed to set git user.email"
            return 1
        }
    fi
    
    log_info "Git identity configuration completed"
}

# ---------------------------------------------------------------------------
# The credential decision
# ---------------------------------------------------------------------------
#
# The READ token is asked for only when it is NEEDED, and need is decided by
# questions that can be answered without a token:
#
#   both repositories already cloned          -> not needed, never prompt
#   a clone is needed, and a usable token is
#     in the environment                      -> use it
#     in the cluster Secret (a re-run)        -> use it, never prompt
#   a clone is needed and neither holds one   -> prompt
#
# PRESENCE IS NOT VALIDITY. A fine-grained PAT expires after at most 366 days;
# on that day the Secret still exists and the token in it is dead. Only asking
# GitHub catches it, so every candidate is validated against the repositories
# this script clones before it is used.

# True when at least one clone target is not a valid git repository.
a_clone_is_needed() {
    local dir
    for dir in "$MDC_REPO_DIR" "$COLLECTIONS_REPO_DIR"; do
        git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
    done
    return 1
}

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

# Asks GitHub whether this token reaches one repository: 200 means yes, and a
# repository the token does not cover answers 404 — a fine-grained PAT is
# invisible to what it was not granted. Anything but 200 — expired, revoked,
# awaiting org approval, wrong scope — means we need a new one.
pat_reads_repo() {
    local token="$1" repo="$2" code
    [[ -n "$token" ]] || return 1

    # THE WHOLE CREDENTIAL-BEARING PART RUNS IN A SUBSHELL WITH ITS OWN EXIT
    # TRAP, and the scoping is the point: the trap and the directory die with
    # the subshell on every path out — normal return, error, SIGINT, SIGTERM.
    #
    # /run, NOT /tmp: Credential Lifecycle §2.6 invariant 1 requires a transient
    # credential on a memory-backed file, never persistent disk; `mktemp -d`
    # alone lands in /tmp, which is the root filesystem.
    #
    # NO `-f`: with --fail, curl exits non-zero on 4xx AFTER `-w` has printed
    # the status, and a `|| echo 000` fallback would concatenate to "404000".
    code="$(
        cfgdir="$(mktemp -d -p /run)" || exit 1
        trap 'rm -rf "$cfgdir"' EXIT
        chmod 700 "$cfgdir"
        printf 'header = "Authorization: Bearer %s"\n' "$token" > "${cfgdir}/curlrc"
        chmod 600 "${cfgdir}/curlrc"
        curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
            --config "${cfgdir}/curlrc" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/${GITHUB_OWNER}/${repo}" 2>/dev/null
    )"
    [[ "${code:-000}" == "200" ]]
}

# The token must reach BOTH repositories this script clones — that is the
# READ token's scope per the runbook, and a token that covers one and not the
# other fails here, naming the one it misses, rather than at the second clone.
pat_is_usable() {
    local token="$1" repo
    for repo in "$SKYY_COMMAND_REPO_NAME" "$COLLECTIONS_REPO_NAME"; do
        if ! pat_reads_repo "$token" "$repo"; then
            log_warn "The token cannot read ${GITHUB_OWNER}/${repo}"
            return 1
        fi
    done
    return 0
}

# Sets PAT, or exits. Order is cheapest-first: an env var costs nothing to
# check, the cluster costs a kubectl call, and only if both come up empty is a
# human interrupted.
resolve_pat() {
    if [[ -n "${GITHUB_READ_PAT:-}" ]]; then
        log_info "Token supplied in the environment; validating..."
        if pat_is_usable "$GITHUB_READ_PAT"; then
            PAT="$GITHUB_READ_PAT"
            log_info "Token valid for ${SKYY_COMMAND_REPO_NAME} and ${COLLECTIONS_REPO_NAME}"
            return 0
        fi
        log_error "GITHUB_READ_PAT is set but cannot read the repositories above."
        log_error "  Expired, revoked, awaiting org approval, or missing Contents:Read on one of them."
        exit 1
    fi

    local existing
    existing="$(read_pat_from_cluster)"
    if [[ -n "$existing" ]]; then
        log_info "Found the READ token in the k3s Secret ${PAT_SECRET_NS}/${PAT_SECRET_NAME}; validating..."
        if pat_is_usable "$existing"; then
            PAT="$existing"
            log_info "Stored token is valid — not asking you for one"
            return 0
        fi
        log_warn "The stored token is present but NO LONGER VALID for these repositories."
        log_warn "  Fine-grained tokens expire after at most 366 days; this is the usual cause."
        log_warn "  A new one is needed — mint and re-place it per guide/github_credentials.md."
    fi

    # READ FROM THE TERMINAL, NOT STDIN. Under `curl | bash`, stdin IS the
    # script — a plain `read` would consume the next lines of this file and
    # execute nothing. /dev/tty is the operator's keyboard regardless of how
    # the script arrived.
    if [[ ! -r /dev/tty ]]; then
        log_error "A token is needed and there is no terminal to ask on."
        log_error "  Re-run interactively, or set GITHUB_READ_PAT and use 'sudo -E'."
        exit 1
    fi

    echo "" >&2
    log_info "The MDC's READ token is needed to clone ${GITHUB_OWNER}/${SKYY_COMMAND_REPO_NAME}"
    log_info "and ${GITHUB_OWNER}/${COLLECTIONS_REPO_NAME}."
    log_info "  A GitHub fine-grained token, READ-ONLY, covering those repositories:"
    log_info "    Contents: Read-only   (Metadata sets itself)"
    log_info "  The mint is the runbook's: mdc-master-planning/guide/github_credentials.md"
    echo "" >&2
    printf "Paste the READ token (input hidden): " >&2
    read -rs PAT < /dev/tty
    echo "" >&2

    if [[ -z "$PAT" ]]; then
        log_error "No token entered."
        exit 1
    fi
    if ! pat_is_usable "$PAT"; then
        log_error "That token cannot read both repositories."
        log_error "  Check: org approval, Contents:Read, and that BOTH repositories are selected."
        exit 1
    fi
    log_info "Token valid for ${SKYY_COMMAND_REPO_NAME} and ${COLLECTIONS_REPO_NAME}"
}

# The askpass helper, created once so every clone can use it. The token's VALUE
# is never in the file — only a reference to the environment.
make_askpass() {
    [[ -n "$ASKPASS_DIR" ]] && return 0
    ASKPASS_DIR="$(mktemp -d -p /run)"; chmod 700 "$ASKPASS_DIR"
    cat > "${ASKPASS_DIR}/askpass.sh" <<'ASKPASS'
#!/usr/bin/env bash
case "$1" in
    Username*) echo "x-access-token" ;;
    *)         echo "${GITHUB_READ_PAT_INTERNAL}" ;;
esac
ASKPASS
    chmod 700 "${ASKPASS_DIR}/askpass.sh"
}

# Runs git with the token supplied through GIT_ASKPASS. THE FOUR SURFACES THE
# TOKEN MUST NOT REACH, and how each is closed:
#   argv        -> GIT_ASKPASS supplies it; never an argument
#   remote URL  -> the URL in .git/config carries no credential
#   .git/config -> follows from the above, and is ASSERTED after every clone
#   cred store  -> `-c credential.helper=` neutralises any inherited helper
# Same shape as skyy-command's activities/git/_pat_auth.py, in shell, because
# the installer runs before any of that code is on the box.
git_with_token() {
    make_askpass
    GITHUB_READ_PAT_INTERNAL="$PAT" GIT_ASKPASS="${ASKPASS_DIR}/askpass.sh" \
        GIT_TERMINAL_PROMPT=0 git -c credential.helper= "$@"
}

# ---------------------------------------------------------------------------
# Task 5: the two repositories
# ---------------------------------------------------------------------------

# Ownership for IDE access: root:$GROUP_NAME, setgid directories so new files
# inherit the group.
fix_repo_ownership() {
    local dir="$1"
    chown -R root:"$GROUP_NAME" "$dir" || {
        log_warn "Failed to set ownership on $dir (non-fatal, continuing)"
    }
    find "$dir" -type d -exec chmod 2775 {} \; || {
        log_warn "Failed to set directory permissions on $dir (non-fatal, continuing)"
    }
}

# Asserted rather than assumed: a token in .git/config is exactly the durable
# copy this script exists to avoid, and it would outlive every later stage.
assert_remote_is_clean() {
    local dir="$1" origin
    origin="$(git -C "$dir" remote get-url origin 2>/dev/null || echo "")"
    if [[ "$origin" == https://*@* ]]; then
        log_error "Stored remote of $dir contains a credential — refusing to continue."
        exit 1
    fi
}

# One repository, converged: present as a valid git repository, origin at the
# clean HTTPS URL, owned for IDE access. Clones over the READ token when absent.
# An existing checkout is not pulled — updates are other workflows' — but its
# origin is moved to the clean URL: the platform reaches GitHub over HTTPS with
# a token, and an SSH-alias remote resolves to a key the platform does not hold.
ensure_repo_cloned() {
    local repo="$1" dir="$2"
    local clean_url="https://github.com/${GITHUB_OWNER}/${repo}.git"

    if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
        log_info "Repository present at $dir (idempotent: skipping clone/pull)"

        local current_remote
        current_remote="$(git -C "$dir" remote get-url origin 2>/dev/null || echo "")"
        if [[ "$current_remote" != "$clean_url" ]]; then
            log_info "Moving origin to the clean HTTPS URL"
            log_info "  Current: $current_remote"
            log_info "  New:     $clean_url"
            git -C "$dir" remote set-url origin "$clean_url" || {
                log_error "Failed to set origin on $dir"
                return 1
            }
        else
            log_info "Origin already correct: $clean_url"
        fi
        assert_remote_is_clean "$dir"

        local repo_owner
        repo_owner="$(stat -c "%U:%G" "$dir" 2>/dev/null)"
        if [[ "$repo_owner" != "root:$GROUP_NAME" ]]; then
            log_info "Repository ownership needs update: current=$repo_owner, expected=root:$GROUP_NAME"
            fix_repo_ownership "$dir"
        else
            log_info "Repository ownership already correct: root:$GROUP_NAME"
        fi
        return 0
    fi

    if [[ -d "$dir" ]]; then
        log_error "Directory exists but is not a valid git repository: $dir"
        log_error "This may indicate a corrupted or incomplete clone"
        log_error "Please remove the directory manually and try again:"
        log_error "  rm -rf $dir"
        return 1
    elif [[ -e "$dir" ]]; then
        log_error "Path exists but is not a directory: $dir"
        log_error "Please remove it manually and try again:"
        log_error "  rm -f $dir"
        return 1
    fi

    local parent_dir
    parent_dir="$(dirname "$dir")"
    if [[ ! -d "$parent_dir" ]]; then
        log_info "Creating parent directory: $parent_dir"
        mkdir -p "$parent_dir" || {
            log_error "Failed to create parent directory: $parent_dir"
            return 1
        }
    fi

    log_info "Cloning ${GITHUB_OWNER}/${repo} to $dir (this may take a moment)..."
    if ! git_with_token clone "$clean_url" "$dir"; then
        log_error "Clone of ${GITHUB_OWNER}/${repo} failed despite a token that validated moments ago."
        log_error "  Network, or the repository's default branch is not clonable."
        return 1
    fi
    assert_remote_is_clean "$dir"
    fix_repo_ownership "$dir"
    log_info "Repository cloned: $dir (root:$GROUP_NAME, directories 2775)"
}

clone_repos() {
    ensure_repo_cloned "$SKYY_COMMAND_REPO_NAME" "$MDC_REPO_DIR" || return 1
    ensure_repo_cloned "$COLLECTIONS_REPO_NAME" "$COLLECTIONS_REPO_DIR" || return 1
}

# Task 6: Launch private bootstrap script
launch_private_bootstrap() {
    log_info "Preparing to launch private bootstrap script from skyy-command..."
    
    local private_bootstrap="$MDC_REPO_DIR/lib/temporal/scripts/bootstrap/bootstrap.sh"

    # Verify repository was cloned successfully
    if [[ ! -d "$MDC_REPO_DIR" ]]; then
        log_error "Skyy-Command repository directory not found: $MDC_REPO_DIR"
        log_error "Please ensure the repository was cloned successfully in the previous step"
        return 1
    fi

    # Install the host Python prerequisites (PyYAML, requests) pinned from the
    # repo's single constraints authority (Image Pipeline Standard §4.1), so the
    # private bootstrap's dependency checks pass without ad-hoc apt/pip installs.
    local host_prereqs="$MDC_REPO_DIR/scripts/install_host_prereqs.sh"
    if [[ -f "$host_prereqs" ]]; then
        log_info "Installing host Python prerequisites (pinned via constraints.txt)..."
        if ! bash "$host_prereqs"; then
            log_error "Host prerequisite install failed: $host_prereqs"
            log_error "Fix the error above and re-run; the private bootstrap needs these deps"
            return 1
        fi
    else
        log_warn "Host-prereqs script not found ($host_prereqs) — older repo revision; continuing"
    fi
    
    # Verify private bootstrap script exists
    if [[ ! -f "$private_bootstrap" ]]; then
        log_error "Private bootstrap script not found at: $private_bootstrap"
        log_error "Expected location: $MDC_REPO_DIR/lib/temporal/scripts/bootstrap/bootstrap.sh"
        log_error "Please verify:"
        log_error "  1. The skyy-command repository was cloned correctly"
        log_error "  2. The repository contains the expected directory structure"
        log_error "  3. You have access to the correct branch/version"
        return 1
    fi
    
    # Make sure the script is executable (idempotent)
    if [[ ! -x "$private_bootstrap" ]]; then
        log_info "Making private bootstrap script executable..."
        chmod +x "$private_bootstrap" || {
            log_error "Failed to make private bootstrap script executable"
            return 1
        }
    else
        log_info "Private bootstrap script is already executable (idempotent: skipping)"
    fi
    
    log_info ""
    log_info "═══════════════════════════════════════════════════════════════"
    log_info "Launching Private Bootstrap Script"
    log_info "═══════════════════════════════════════════════════════════════"
    log_info "Script location: $private_bootstrap"
    log_info "All output from the private bootstrap will stream below..."
    log_info "═══════════════════════════════════════════════════════════════"
    log_info ""
    
    # Execute the private bootstrap script
    # Using bash with explicit unbuffered output to ensure log streaming
    # The script's output will stream directly to stdout/stderr
    bash "$private_bootstrap"
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        log_info ""
        log_info "═══════════════════════════════════════════════════════════════"
        log_info "Private Bootstrap Script Completed Successfully"
        log_info "═══════════════════════════════════════════════════════════════"
        return 0
    else
        log_error ""
        log_error "═══════════════════════════════════════════════════════════════"
        log_error "Private Bootstrap Script Failed"
        log_error "═══════════════════════════════════════════════════════════════"
        log_error "Exit code: $exit_code"
        log_error "Please review the output above for error details"
        log_error "Common issues:"
        log_error "  - Configuration file errors (check config.yaml and .env)"
        log_error "  - Docker/container issues (check Docker is running)"
        log_error "  - Network connectivity issues"
        log_error "  - Insufficient permissions"
        return 1
    fi
}

# Main execution
ensure_qemu_guest_agent() {
    # The control-plane seed is the ONE VM built by hand (not cloned from a DAS
    # golden template), so it's the only VM that doesn't inherit the universal
    # qemu-guest-agent requirement (DAS Template Standard §2). Install it here so
    # the seed matches the fleet — enables Proxmox-side management + consistent
    # (fs-freeze) PBS backups of the control plane. Non-fatal: bootstrap does not
    # depend on it.
    #
    # NOTE: the in-guest package alone is NOT enough — the Proxmox `agent: 1` flag
    # must be set at VM-CREATE time (operator: `qm set <vmid> --agent 1`) so the
    # virtio-serial channel exists from first boot. Set it when creating the seed.
    if dpkg -s qemu-guest-agent >/dev/null 2>&1; then
        log_info "qemu-guest-agent already installed"
    else
        log_info "Installing qemu-guest-agent (hypervisor integration + backup fs-freeze)..."
        apt-get update -qq
        apt-get install -y qemu-guest-agent \
            || log_warn "qemu-guest-agent install failed (non-fatal; set --agent 1 at VM create + reinstall)"
    fi
}

main() {
    log_info "═══════════════════════════════════════════════════════════════"
    log_info "Skyy-Command Public Installer"
    log_info "═══════════════════════════════════════════════════════════════"
    log_info "This script sets up the initial environment and launches the"
    log_info "private bootstrap script to complete Temporal installation."
    log_info "═══════════════════════════════════════════════════════════════"
    echo ""
    
    # Check if running as root
    log_info "Verifying root access..."
    check_root
    log_info "Root access verified"
    echo ""
    
    # Host prerequisite — qemu-guest-agent (hypervisor integration). The seed is
    # the one hand-built VM that doesn't inherit it from a DAS golden template.
    log_info "Ensuring qemu-guest-agent (host prerequisite)..."
    ensure_qemu_guest_agent
    echo ""

    # Execute tasks in order with detailed error handling
    log_info "Starting installation tasks..."
    echo ""
    
    log_info "[Task 0/6] Setting up folder structure and user group..."
    if setup_folder_and_group; then
        log_info "[Task 0/6] ✓ Completed"
    else
        log_error "[Task 0/6] ✗ Failed"
        log_error "Failed to setup folder structure and group"
        log_error "This is a critical error - cannot proceed without base directory"
        exit 1
    fi
    echo ""

    # The one human interruption, taken FIRST — before the long installs —
    # and only when a clone is actually needed.
    log_info "[Task 1/6] Deciding whether the READ token is needed..."
    if a_clone_is_needed; then
        resolve_pat
    else
        log_info "Both repositories are already cloned — no token needed"
    fi
    log_info "[Task 1/6] ✓ Completed"
    echo ""

    log_info "[Task 2/6] Installing Docker and Docker Compose..."
    if install_docker; then
        log_info "[Task 2/6] ✓ Completed"
    else
        log_error "[Task 2/6] ✗ Failed"
        log_error "Failed to install Docker"
        log_error "Docker is required for Temporal infrastructure"
        exit 1
    fi
    echo ""

    log_info "[Task 3/6] Installing Helm..."
    if install_helm; then
        log_info "[Task 3/6] ✓ Completed"
    else
        log_error "[Task 3/6] ✗ Failed"
        log_error "Failed to install helm"
        log_error "helm is required by the private bootstrap's chart-rendering pipeline"
        exit 1
    fi
    echo ""

    log_info "[Task 4/6] Installing Git and configuring identity..."
    if install_git; then
        log_info "[Task 4/6] ✓ Completed"
    else
        log_error "[Task 4/6] ✗ Failed"
        log_error "Failed to install Git"
        log_error "Git is required to clone the repositories"
        exit 1
    fi
    echo ""

    log_info "[Task 5/6] Cloning skyy-command and mdc-ansible-collections..."
    if clone_repos; then
        log_info "[Task 5/6] ✓ Completed"
    else
        log_error "[Task 5/6] ✗ Failed"
        log_error "Failed to clone the repositories"
        log_error "Please verify:"
        log_error "  - The READ token covers both repositories with Contents: Read"
        log_error "  - Network connectivity is available"
        exit 1
    fi
    echo ""

    # The token has done its only job. It is not the private bootstrap's to
    # inherit here — nothing downstream in this run reads it.
    PAT=""

    log_info "[Task 6/6] Launching private bootstrap script..."
    if launch_private_bootstrap; then
        log_info "[Task 6/6] ✓ Completed"
    else
        log_error "[Task 6/6] ✗ Failed"
        log_error "Failed to launch private bootstrap script"
        log_error "Please review the private bootstrap output above for details"
        exit 1
    fi
    echo ""
    
    log_info ""
    log_info "═══════════════════════════════════════════════════════════════"
    log_info "Public Installer Completed Successfully"
    log_info "═══════════════════════════════════════════════════════════════"
    log_info "The folder structure and the skyy-command and mdc-ansible-collections"
    log_info "repos are in place, and the private bootstrap has been launched (output above)."
    log_info ""
    log_info "Follow the instructions printed by the private bootstrap above:"
    log_info "  - On a fresh VM, the bootstrap will have created config.yaml and .env"
    log_info "    from templates and exited. Edit those files, then re-run:"
    log_info "      sudo $MDC_REPO_DIR/lib/temporal/scripts/bootstrap/bootstrap.sh"
    log_info "  - On the second run, the bootstrap installs K3s and deploys Temporal."
    log_info "  - When Phase 2 completes, start the Genesis workflow to finish the install."
    log_info "═══════════════════════════════════════════════════════════════"
}

# Run main function
main "$@"
