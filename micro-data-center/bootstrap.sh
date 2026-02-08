#!/bin/bash
#
# Micro Data Center Public Installer Script
# 
# This script is the public entry point for installing the Micro Data Center platform.
# It can be downloaded via curl and sets up the initial environment, then delegates
# to the private bootstrap script in the micro-data-center repository.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/helloskyy-io/installer/main/micro-data-center/bootstrap.sh | sudo bash
#
# Target state: "micro-data-center repo is cloned and private bootstrap script is ready to run"

set -euo pipefail

# Configuration

# Base directory for all Skyy-Net repositories
BASE_DIR="${BASE_DIR:-/opt/skyy-net}"

# MicroDatacenter repository directory - where the micro-data-center repo will be cloned
MDC_REPO_DIR="${MDC_REPO_DIR:-$BASE_DIR/micro-data-center}"

# GitHub repository URL for MicroDatacenter repo
GITHUB_REPO="${GITHUB_REPO:-git@github.com:helloskyy-io/micro-data-center.git}"

# User group name for collaborative development access
GROUP_NAME="${GROUP_NAME:-skyy-net}"

# Development user to add to the group (for SSH access via IDE)
DEV_USER="${DEV_USER:-puma}"

# SSH directory for deploy keys (root's .ssh directory)
SSH_DIR="${SSH_DIR:-/root/.ssh}"

# SSH deploy key name for MicroDatacenter repo
KEY_NAME="micro-data-center-deploy"

# SSH deploy key paths (private and public)
DEPLOY_KEY_PATH="${DEPLOY_KEY_PATH:-$SSH_DIR/$KEY_NAME}"
DEPLOY_KEY_PUB="${DEPLOY_KEY_PUB:-$SSH_DIR/$KEY_NAME.pub}"

# SSH config file path
SSH_CONFIG="${SSH_CONFIG:-$SSH_DIR/config}"

# SSH host alias for GitHub access via deploy key
SSH_HOST_ALIAS="micro-data-center-github"

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

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Task 0: Create folder structure and user group
setup_folder_and_group() {
    log_info "Setting up folder structure and user group..."
    
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
    
    # Note: We do NOT change file permissions - Git preserves them correctly
    # The setgid bit (2775) on directories ensures new files get the correct group automatically
    
    log_info "Folder structure and group setup completed successfully"
    log_info "  Directory: $BASE_DIR"
    log_info "  Owner: root"
    log_info "  Group: $GROUP_NAME"
    log_info "  Directory permissions: 2775 (setgid enabled - new files inherit group)"
    log_info "  Note: File permissions are preserved from Git (not modified)"
}

# Task 1: Install Docker + Compose
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
}

# Task 2: Install git and configure identity
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

# Task 3: Configure SSH / deploy key for private GitHub repo
configure_deploy_key() {
    log_info "Configuring SSH deploy key for micro-data-center repo..."
    
    # Ensure SSH directory exists with correct permissions
    if [[ ! -d "$SSH_DIR" ]]; then
        log_info "Creating SSH directory: $SSH_DIR"
        mkdir -p "$SSH_DIR"
        chmod 700 "$SSH_DIR"
    else
        log_info "SSH directory already exists: $SSH_DIR"
    fi
    
    # Check if key already exists
    local key_exists=false
    if [[ -f "$DEPLOY_KEY_PATH" && -f "$DEPLOY_KEY_PUB" ]]; then
        key_exists=true
        log_info "Deploy key already exists: $DEPLOY_KEY_PATH (idempotent: skipping generation)"
    else
        # Generate new Ed25519 key pair
        log_info "Generating new Ed25519 SSH key pair..."
        if ssh-keygen -t ed25519 \
            -f "$DEPLOY_KEY_PATH" \
            -N "" \
            -C "micro-data-center-deploy-key-$(hostname)-$(date +%Y%m%d)" \
            -q; then
            chmod 600 "$DEPLOY_KEY_PATH"
            chmod 644 "$DEPLOY_KEY_PUB"
            log_info "SSH key pair generated successfully"
        else
            log_error "Failed to generate SSH key pair"
            return 1
        fi
        
        # Display public key for user to add to GitHub
        echo ""
        log_warn "═══════════════════════════════════════════════════════════════"
        log_warn "ACTION REQUIRED: Add the following public key to GitHub"
        log_warn "═══════════════════════════════════════════════════════════════"
        echo ""
        cat "$DEPLOY_KEY_PUB"
        echo ""
        log_warn "Steps to add key to GitHub:"
        log_warn "  1. Go to: https://github.com/helloskyy-io/micro-data-center/settings/keys"
        log_warn "  2. Click 'Add deploy key'"
        log_warn "  3. Paste the public key above"
        log_warn "  4. For production: Give the key READ access only"
        log_warn "  5. For development: Check 'Allow write access'"
        log_warn "  6. Click 'Add key'"
        echo ""
        log_warn "Press ENTER after you have added the key to GitHub..."
        read -r
    fi
    
    # Add key to SSH config if not already present (idempotent)
    if [[ ! -f "$SSH_CONFIG" ]]; then
        log_info "Creating SSH config file: $SSH_CONFIG"
        touch "$SSH_CONFIG"
        chmod 600 "$SSH_CONFIG"
    fi
    
    if ! grep -q "Host $SSH_HOST_ALIAS" "$SSH_CONFIG" 2>/dev/null; then
        log_info "Adding SSH config entry for micro-data-center repo..."
        cat >> "$SSH_CONFIG" <<EOF

# Micro-data-center repo deploy key
Host $SSH_HOST_ALIAS
    HostName github.com
    User git
    IdentityFile $DEPLOY_KEY_PATH
    IdentitiesOnly yes
EOF
        chmod 600 "$SSH_CONFIG"
        log_info "SSH config updated"
    else
        log_info "SSH config entry already exists for $SSH_HOST_ALIAS (idempotent: skipping)"
    fi
    
    # Always test git access (even if key existed - ensures it's properly configured)
    log_info "Testing SSH connection to GitHub..."
    local access_verified=false
    
    # First try: SSH connection test
    if ssh -T -o StrictHostKeyChecking=no -o IdentitiesOnly=yes \
        -i "$DEPLOY_KEY_PATH" \
        git@github.com 2>&1 | grep -q "successfully authenticated"; then
        log_info "SSH connection test successful"
        access_verified=true
    else
        log_info "SSH connection test inconclusive (this is normal for deploy keys)"
        log_info "Attempting direct git repository access test..."
        
        # Second try: Direct git repository access test
        local test_dir="/tmp/mdc_key_test_$$"
        mkdir -p "$test_dir" || {
            log_error "Failed to create temporary test directory"
            return 1
        }
        
        cd "$test_dir" || {
            log_error "Failed to change to test directory"
            return 1
        }
        
        # Use SSH config alias for testing
        local test_url="${GITHUB_REPO/git@github.com:/git@$SSH_HOST_ALIAS:}"
        if git ls-remote "$test_url" &> /dev/null; then
            log_info "Git repository access test successful - key is properly configured"
            access_verified=true
        else
            log_error "Git repository access test failed"
            log_error ""
            log_error "Troubleshooting steps:"
            log_error "  1. Verify the public key has been added to GitHub"
            log_error "     Public key location: $DEPLOY_KEY_PUB"
            log_error "     GitHub URL: https://github.com/helloskyy-io/micro-data-center/settings/keys"
            log_error "  2. Verify the key has the correct permissions (read for prod, read/write for dev)"
            log_error "  3. Verify the repository exists and is accessible"
            log_error "  4. If the key was just added, wait a few seconds and try again"
            log_error ""
            
            if [[ "$key_exists" == "true" ]]; then
                log_warn "Key exists but access test failed - key may not be added to GitHub"
                log_warn "Displaying public key again for verification:"
                echo ""
                cat "$DEPLOY_KEY_PUB"
                echo ""
            fi
        fi
        
        cd / || true
        rm -rf "$test_dir" || true
    fi
    
    # Final verification
    if [[ "$access_verified" != "true" ]]; then
        if [[ "${SKIP_KEY_CHECK:-false}" != "true" ]]; then
            log_error "Git access verification failed - cannot proceed without repository access"
            log_error "Set SKIP_KEY_CHECK=true to continue anyway (not recommended)"
            return 1
        else
            log_warn "Skipping key check (SKIP_KEY_CHECK=true) - proceeding anyway"
        fi
    else
        log_info "SSH key configuration verified successfully"
    fi
}

# Task 4: Clone MicroDatacenter repo
clone_repo() {
    log_info "Checking micro-data-center repository..."
    
    # Convert GitHub URL to use SSH config alias if deploy key is configured
    local repo_url="$GITHUB_REPO"
    if [[ -f "$DEPLOY_KEY_PATH" && -f "$SSH_CONFIG" ]] && \
       grep -q "Host $SSH_HOST_ALIAS" "$SSH_CONFIG" 2>/dev/null; then
        # Use SSH config alias: git@github.com -> git@micro-data-center-github
        # Keep the git@ prefix, only replace the hostname
        repo_url="${GITHUB_REPO/git@github.com:/git@$SSH_HOST_ALIAS:}"
        log_info "Using SSH config alias: git@$SSH_HOST_ALIAS"
    else
        log_warn "SSH config alias not found, using direct GitHub URL"
        log_warn "This may fail if SSH keys are not properly configured"
    fi
    
    # Check if repository already exists and is a valid git repository (idempotent)
    if [[ -d "$MDC_REPO_DIR" ]] && [[ -d "$MDC_REPO_DIR/.git" ]]; then
        log_info "Repository directory already exists at: $MDC_REPO_DIR (idempotent: checking validity)"
        
        # Verify it's a valid git repository
        if git -C "$MDC_REPO_DIR" rev-parse --git-dir > /dev/null 2>&1; then
            log_info "Valid git repository detected"
            
            # Update remote URL if it has changed (idempotent)
            cd "$MDC_REPO_DIR" || {
                log_error "Failed to change to repository directory: $MDC_REPO_DIR"
                return 1
            }
            
            local current_remote=$(git remote get-url origin 2>/dev/null || echo "")
            
            if [[ "$current_remote" != "$repo_url" ]]; then
                log_info "Remote URL differs, updating..."
                log_info "  Current: $current_remote"
                log_info "  New:     $repo_url"
                if git remote set-url origin "$repo_url"; then
                    log_info "Remote URL updated successfully"
                else
                    log_warn "Failed to update remote URL, continuing with existing remote"
                fi
            else
                log_info "Remote URL already correct: $repo_url (idempotent: skipping update)"
            fi
            
            # Verify and fix ownership if needed (for IDE access)
            local repo_owner=$(stat -c "%U:%G" "$MDC_REPO_DIR" 2>/dev/null)
            if [[ "$repo_owner" != "root:$GROUP_NAME" ]]; then
                log_info "Repository ownership needs update: current=$repo_owner, expected=root:$GROUP_NAME"
                log_info "Fixing ownership to ensure IDE access works correctly..."
                chown -R root:"$GROUP_NAME" "$MDC_REPO_DIR" || {
                    log_warn "Failed to set ownership on existing repository (non-fatal, continuing)"
                }
                # Ensure directory permissions have setgid bit
                find "$MDC_REPO_DIR" -type d -exec chmod 2775 {} \; || {
                    log_warn "Failed to set directory permissions (non-fatal, continuing)"
                }
                log_info "Repository ownership and permissions updated"
            else
                log_info "Repository ownership already correct: root:$GROUP_NAME (idempotent: skipping)"
            fi
            
            # Bootstrap script only ensures repo exists - don't pull updates
            # (Updates should be handled by separate workflows/processes)
            log_info "Repository is ready (idempotent: skipping clone/pull)"
            return 0
        else
            log_error "Directory exists but is not a valid git repository: $MDC_REPO_DIR"
            log_error "This may indicate a corrupted or incomplete clone"
            log_error "Please remove the directory manually and try again:"
            log_error "  rm -rf $MDC_REPO_DIR"
            return 1
        fi
    elif [[ -e "$MDC_REPO_DIR" ]]; then
        # Path exists but is not a directory (could be a file)
        log_error "Path exists but is not a directory: $MDC_REPO_DIR"
        log_error "Please remove it manually and try again:"
        log_error "  rm -f $MDC_REPO_DIR"
        return 1
    else
        # Repository doesn't exist, clone it
        log_info "Repository not found, cloning from: $repo_url"
        log_info "Target directory: $MDC_REPO_DIR"
        
        # Ensure parent directory exists
        local parent_dir=$(dirname "$MDC_REPO_DIR")
        if [[ ! -d "$parent_dir" ]]; then
            log_info "Creating parent directory: $parent_dir"
            mkdir -p "$parent_dir" || {
                log_error "Failed to create parent directory: $parent_dir"
                return 1
            }
        fi
        
        log_info "Cloning repository (this may take a moment)..."
        if git clone "$repo_url" "$MDC_REPO_DIR"; then
            log_info "Repository cloned successfully"
            log_info "Location: $MDC_REPO_DIR"
            
            # Fix ownership of cloned files to ensure correct group (for IDE access)
            log_info "Setting ownership of cloned repository to root:$GROUP_NAME..."
            chown -R root:"$GROUP_NAME" "$MDC_REPO_DIR" || {
                log_warn "Failed to set ownership on cloned repository (non-fatal, continuing)"
            }
            
            # Ensure directory permissions have setgid bit (so new files inherit group)
            log_info "Setting directory permissions with setgid bit..."
            find "$MDC_REPO_DIR" -type d -exec chmod 2775 {} \; || {
                log_warn "Failed to set directory permissions (non-fatal, continuing)"
            }
            
            log_info "Repository ownership and permissions configured"
            log_info "  Owner: root"
            log_info "  Group: $GROUP_NAME"
            log_info "  Directory permissions: 2775 (setgid - new files inherit group)"
        else
            log_error "Failed to clone repository"
            log_error "Please verify:"
            log_error "  1. SSH key has been added to GitHub"
            log_error "  2. Repository URL is correct: $repo_url"
            log_error "  3. Network connectivity is available"
            log_error "  4. You have access to the repository"
            return 1
        fi
    fi
}

# Task 5: Launch private bootstrap script
launch_private_bootstrap() {
    log_info "Preparing to launch private bootstrap script from micro-data-center..."
    
    local private_bootstrap="$MDC_REPO_DIR/components/temporal/scripts/bootstrap/bootstrap.sh"
    
    # Verify repository was cloned successfully
    if [[ ! -d "$MDC_REPO_DIR" ]]; then
        log_error "Micro-data-center repository directory not found: $MDC_REPO_DIR"
        log_error "Please ensure the repository was cloned successfully in the previous step"
        return 1
    fi
    
    # Verify private bootstrap script exists
    if [[ ! -f "$private_bootstrap" ]]; then
        log_error "Private bootstrap script not found at: $private_bootstrap"
        log_error "Expected location: $MDC_REPO_DIR/components/temporal/scripts/bootstrap/bootstrap.sh"
        log_error "Please verify:"
        log_error "  1. The micro-data-center repository was cloned correctly"
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
main() {
    log_info "═══════════════════════════════════════════════════════════════"
    log_info "Micro Data Center Public Installer"
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
    
    # Execute tasks in order with detailed error handling
    log_info "Starting installation tasks..."
    echo ""
    
    log_info "[Task 0/5] Setting up folder structure and user group..."
    if setup_folder_and_group; then
        log_info "[Task 0/5] ✓ Completed"
    else
        log_error "[Task 0/5] ✗ Failed"
        log_error "Failed to setup folder structure and group"
        log_error "This is a critical error - cannot proceed without base directory"
        exit 1
    fi
    echo ""
    
    log_info "[Task 1/5] Installing Docker and Docker Compose..."
    if install_docker; then
        log_info "[Task 1/5] ✓ Completed"
    else
        log_error "[Task 1/5] ✗ Failed"
        log_error "Failed to install Docker"
        log_error "Docker is required for Temporal infrastructure"
        exit 1
    fi
    echo ""
    
    log_info "[Task 2/5] Installing Git and configuring identity..."
    if install_git; then
        log_info "[Task 2/5] ✓ Completed"
    else
        log_error "[Task 2/5] ✗ Failed"
        log_error "Failed to install Git"
        log_error "Git is required to clone the micro-data-center repository"
        exit 1
    fi
    echo ""
    
    log_info "[Task 3/5] Configuring SSH deploy key for micro-data-center repository..."
    if configure_deploy_key; then
        log_info "[Task 3/5] ✓ Completed"
    else
        log_error "[Task 3/5] ✗ Failed"
        log_error "Failed to configure deploy key"
        log_error "SSH key is required to access the private micro-data-center repository"
        log_error "Please ensure the key was added to GitHub and try again"
        exit 1
    fi
    echo ""
    
    log_info "[Task 4/5] Cloning micro-data-center repository..."
    if clone_repo; then
        log_info "[Task 4/5] ✓ Completed"
    else
        log_error "[Task 4/5] ✗ Failed"
        log_error "Failed to clone micro-data-center repository"
        log_error "Please verify:"
        log_error "  - SSH key has been added to GitHub"
        log_error "  - Repository exists and is accessible"
        log_error "  - Network connectivity is available"
        exit 1
    fi
    echo ""
    
    log_info "[Task 5/5] Launching private bootstrap script..."
    if launch_private_bootstrap; then
        log_info "[Task 5/5] ✓ Completed"
    else
        log_error "[Task 5/5] ✗ Failed"
        log_error "Failed to launch private bootstrap script"
        log_error "Please review the private bootstrap output above for details"
        exit 1
    fi
    echo ""
    
    log_info ""
    log_info "═══════════════════════════════════════════════════════════════"
    log_info "Public Installer Completed Successfully"
    log_info "═══════════════════════════════════════════════════════════════"
    log_info "All installation tasks have been completed."
    log_info "The Micro Data Center platform should now be operational."
    log_info ""
    log_info "Next steps:"
    log_info "  - Review the Temporal UI at http://localhost:8080"
    log_info "  - Start the Genesis workflow to complete initial setup"
    log_info "═══════════════════════════════════════════════════════════════"
}

# Run main function
main "$@"
