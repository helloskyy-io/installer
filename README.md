# Installer Repository

This repository contains public installer scripts for HelloSkyy platform components. Each component has its own directory with a dedicated installer script and documentation.

## Available Installers

### [Micro Data Center](./micro-data-center/)

The installer for the Micro Data Center platform (Skyy-Command).

**Quick Start:**
```bash
curl -fsSL https://raw.githubusercontent.com/helloskyy-io/installer/main/micro-data-center/bootstrap.sh | sudo bash
```

See [micro-data-center/README.md](./micro-data-center/README.md) for detailed documentation.

## Repository Structure

```
installer/
├── README.md                    # This file
└── micro-data-center/           # Micro Data Center installer
    ├── bootstrap.sh            # Public installer script
    └── README.md               # Component-specific documentation
```

## Adding New Installers

To add a new component installer:

1. Create a new directory at the root level (e.g., `installer/my-component/`)
2. Add your `bootstrap.sh` script and `README.md` in that directory
3. Update this README to include the new component

## License

MIT License with Non-Competition Clause — see [LICENSE](./LICENSE) file

This software is open source but restricts commercial use in competing applications. For commercial licensing inquiries, contact info@helloskyy.io
