# Installer Repository

Public installer scripts for HelloSkyy platform components.

## Quick Start

### Skyy-Command (Micro Data Center control plane)

```bash
curl -fsSL https://raw.githubusercontent.com/helloskyy-io/installer/main/skyy-command/bootstrap.sh | sudo bash
```

See [skyy-command/README.md](./skyy-command/README.md) for detailed documentation.

### image-manager (image build-and-distribution tier)

**Read [image-manager/README.md](./image-manager/README.md) first** — this one needs a GitHub
token created before you run anything, and the permissions UI is not self-explanatory.

```bash
curl -fsSL https://raw.githubusercontent.com/helloskyy-io/installer/main/image-manager/bootstrap.sh | sudo bash
```

It prompts for the token, hidden, and only when it needs one — nothing on the command line, nothing
in shell history.


## License

MIT License with Non-Competition Clause — see [LICENSE](./LICENSE) file.

For commercial licensing inquiries, contact info@helloskyy.io
