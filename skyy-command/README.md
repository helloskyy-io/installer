# Skyy-Command Installer

This repository contains the public installer script for the Skyy-Command control plane.

## Quick Start

Run the installer on a fresh Ubuntu VM:

```bash
curl -fsSL https://raw.githubusercontent.com/helloskyy-io/installer/main/skyy-command/bootstrap.sh | sudo bash
```

## What This Does

The public installer script performs the following steps:

1. **Setup folder structure and user group** - Creates `/opt/skyy-net` and `skyy-net` group; auto-detects the invoking operator via `$SUDO_USER` and adds them to the group with POSIX default ACLs
2. **Decide whether the READ token is needed** - Only when a repository below is not yet cloned. A token already in the k3s Secret `skyy-command/github-read` (a re-run) is validated against GitHub and reused; otherwise the script prompts for it — typed at the terminal, hidden, never on the command line. For an unattended run set `GITHUB_READ_PAT` and use `sudo -E`
   - The token is the MDC's **READ** token: a GitHub fine-grained PAT, `Contents: Read-only` on `Skyy-Command` and `mdc-ansible-collections` (and the other platform repos the MDC clones). The mint is the runbook's: `mdc-master-planning/guide/github_credentials.md`
   - It is validated against **both** repositories before use; presence is not validity — an expired token is caught here, not three steps later
3. **Install Docker** - Installs Docker and Docker Compose
4. **Install Helm** - Installs helm (required by the private bootstrap's chart-rendering pipeline)
5. **Install Git** - Ensures Git is available and configures git identity
6. **Clone the repositories** - Clones `skyy-command` and, beside it, `mdc-ansible-collections` (the private bootstrap's worker-image bake reads the collections from that clone) over HTTPS with the READ token supplied through `GIT_ASKPASS`. The token is never in a remote URL or `.git/config` — the stored remote is asserted credential-free after every clone. An existing checkout is left as it is, with its origin moved to the clean HTTPS URL
7. **Launch private bootstrap** - Clears BOTH carriers of the token — the shell variable and the exported `GITHUB_READ_PAT` an unattended `sudo -E` run was started with, since the private bootstrap runs as a child and inherits the environment — then executes it to complete Temporal setup

## Requirements

- Ubuntu 20.04+ or Debian 11+
- Root access (script must be run with `sudo`)
- Internet connectivity
- The MDC's READ token (GitHub fine-grained PAT) covering `helloskyy-io/Skyy-Command` and `helloskyy-io/mdc-ansible-collections` — minted per `mdc-master-planning/guide/github_credentials.md`

## Repository Structure

```
installer/
└── skyy-command/
    ├── bootstrap.sh    # Public installer script for Skyy-Command
    └── README.md       # This file
```

Additional apps can be added as sibling folders (e.g., `installer/skyy-gate/`, etc.)

The private bootstrap script is located in the `skyy-command` repository at:
`lib/temporal/scripts/bootstrap/bootstrap.sh`

## License

MIT License with Non-Competition Clause — see [LICENSE](../LICENSE) file

This software is open source but restricts commercial use in competing applications. For commercial licensing inquiries, contact info@helloskyy.io
