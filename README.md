# Micro Data Center Installer

This repository contains the public installer script for the Micro Data Center platform.

## Quick Start

Run the installer on a fresh Ubuntu VM:

```bash
curl -fsSL https://raw.githubusercontent.com/helloskyy-io/installer/main/bootstrap.sh | sudo bash
```

## What This Does

The public installer script performs the following steps:

1. **Setup folder structure and user group** - Creates `/opt/skyy-net` and `skyy-net` group
2. **Install Docker** - Installs Docker and Docker Compose
3. **Install Git** - Ensures Git is available and configures git identity
4. **Configure deploy key** - Generates SSH deploy key for micro-data-center repository access
   - **Manual step required**: Script displays the public key and prompts you to add it to GitHub
   - Add the deploy key to: `https://github.com/helloskyy-io/micro-data-center/settings/keys` (Deploy keys section)
   - **Important**: Give the key **read access** (write access not needed for bootstrap)
5. **Clone repository** - Clones micro-data-center repository using the deploy key
6. **Launch private bootstrap** - Executes the private bootstrap script from micro-data-center to complete Temporal setup

## Requirements

- Ubuntu 20.04+ or Debian 11+
- Root access (script must be run with `sudo`)
- Internet connectivity
- GitHub account with access to `helloskyy-io/micro-data-center` repository

## Repository Structure

```
installer/
├── bootstrap.sh    # Public installer script (this repo)
└── README.md       # This file
```

The private bootstrap script is located in the `micro-data-center` repository at:
`components/temporal/scripts/bootstrap/bootstrap.sh`

## License

MIT License — see LICENSE file
