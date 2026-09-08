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
export IMAGE_MANAGER_PAT=github_pat_your_token_here
curl -fsSL https://raw.githubusercontent.com/helloskyy-io/installer/main/image-manager/bootstrap.sh | sudo -E bash
```

`sudo -E` is required — without it the token does not reach the script.


## License

MIT License with Non-Competition Clause — see [LICENSE](./LICENSE) file.

For commercial licensing inquiries, contact info@helloskyy.io
