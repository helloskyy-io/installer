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
2. **Configure operator SSH config** - Appends a wildcard `Host *-github` block (managed via BEGIN/END markers) to `~<operator>/.ssh/config` so per-MDC and per-repo aliases created later by Genesis just work from the operator's shell
3. **Install Docker** - Installs Docker and Docker Compose
4. **Install Helm** - Installs helm (required by the private bootstrap's chart-rendering pipeline)
5. **Install Git** - Ensures Git is available and configures git identity
6. **Configure deploy key** - Generates SSH deploy key for skyy-command repository access
   - **Manual step required**: Script displays the public key and prompts you to add it to GitHub
   - Add the deploy key to: `https://github.com/helloskyy-io/Skyy-Command/settings/keys` (Deploy keys section)
   - **Important**: Give the key **read access** (write access not needed for bootstrap)
7. **Clone repository** - Clones skyy-command repository using the deploy key
8. **Launch private bootstrap** - Executes the private bootstrap script from skyy-command to complete Temporal setup

## Requirements

- Ubuntu 20.04+ or Debian 11+
- Root access (script must be run with `sudo`)
- Internet connectivity
- GitHub account with access to `helloskyy-io/Skyy-Command` repository

## Repository Structure

```
installer/
└── skyy-command/
    ├── bootstrap.sh    # Public installer script for Skyy-Command
    └── README.md       # This file
```

Additional apps can be added as sibling folders (e.g., `installer/skyy-gate/`, etc.)

The private bootstrap script is located in the `skyy-command` repository at:
`components/temporal/scripts/bootstrap/bootstrap.sh`

## License

MIT License with Non-Competition Clause — see [LICENSE](../LICENSE) file

This software is open source but restricts commercial use in competing applications. For commercial licensing inquiries, contact info@helloskyy.io
