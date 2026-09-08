# image-manager — public installer (stage 1)

Stands a fresh VM up to the point where `image-manager` is on disk, then hands off.

```
Stage 1  this script            bare VM  ->  source at /opt/skyy-net/image-manager
Stage 2  <repo>/bootstrap.sh    source   ->  k3s + Temporal + a worker image
Stage 3  Genesis (Temporal)     that     ->  Harbor, the public edge, the build path
```

**Why stage 1 lives here and not in `image-manager`:** this script is what *fetches* that
repository, so it has to be reachable by a machine that does not have it yet — a public URL, no
credential. A stage-1 script inside the repo it clones is a circle.

---

## Before you run it — the VM

This tier is **hand-installed once, by a human, and is never a target of automated standup.** That
is the rule the whole component exists to honour: it is the registry every other product pulls its
images from, so instance zero cannot be installed by pulling an image.

**It assumes a rented VM and nothing else** — no hypervisor, no host agent, no platform underneath.
We run instance zero on our own hardware because we own it, not because it needs to be there.

### Size

| Resource | | Why |
|---|---|---|
| **8 vCPU** | | A container build is CPU-bound. Harbor wants ~4 at its recommended tier; the build needs room without competing with a pull. |
| **16 GB RAM** | | Harbor ~8 GB, k3s + containerd ~1.5, Temporal 2–4, PostgreSQL ~2, the worker ~1, plus build headroom. Steady state lands near 15. |
| **100 GB root** | | OS, k3s, containerd, build scratch. **Rebuildable from this document** — nothing irreplaceable lives here. |
| **250 GB data volume** | **separate disk, mounted at `/data`** | Registry storage and PostgreSQL. **This is the one that must survive a host reinstall**, and it must be growable without one. |

**250 GB is a starting figure, not a sized one.** A registry's disk only goes up — every published
tag stays until something reaps it, and nothing reaps anything yet. **Growing a volume is routine;
shrinking one is involved**, so the cheap mistake is starting small. Start here, watch what it
actually holds, and grow it.

### Why two volumes and not one

Root can be rebuilt from scratch by re-running the installer. **The data volume cannot** — it holds
the images every other product pulls, and losing it is losing the artifacts themselves. Keeping them
apart is what makes "rebuild the box" a routine operation rather than a data-loss event.

**Local storage, deliberately not Ceph.** A registry serves large blobs and a builder writes them;
both want the disk directly. The requirement is *a volume that survives a host reinstall*, and local
storage plus off-host backup satisfies it. Ceph is revisitable later without redesigning anything.

### Preparing the data volume

Confirm the second disk is present and empty — `sdb` below, 250 G, with no filesystem and no
mountpoint:

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT
```

Then create a filesystem on it and mount it permanently:

```bash
sudo mkfs.ext4 -L image-manager-data /dev/sdb && sudo mkdir -p /data && echo 'LABEL=image-manager-data /data ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab && sudo mount -a && df -h /data
```

**Mounted by LABEL, not by `/dev/sdb`.** Device names reorder across reboots, and a wrong-disk mount
on the box everything pulls from is not a failure you want to debug at 3am.

**No partition table, deliberately.** Growing later is then a disk resize on the hypervisor followed
by `resize2fs /dev/sdb` — with no partition edge to move first.

### Other requirements

- **Debian or Ubuntu.** The installer uses `apt-get`; that is its only environmental assumption.
- **Root, via `sudo`.** The install writes `/etc/rancher`, `/var/lib` and systemd units.
- **Outbound HTTPS** to `github.com` and `get.k3s.io`.
- **Back the data volume up off-host.** Nothing in this component does it for you, and the backup is
  what makes the hand-install rule survivable.

---

## Before you run it — create the token

The installer clones one private repository, so it needs one read-only credential. **It will not
generate an SSH key and it will never ask you to paste anything into GitHub mid-install.**

**The permissions UI is not obvious, and this is the step people get stuck on.** A fine-grained
token does not have a single read/write switch — it has roughly twenty permission types, each with
its own dropdown, all defaulting to **No access**. You change exactly one.

### Step by step

1. Go to **https://github.com/settings/personal-access-tokens/new**

   This is your **personal** account settings. An organisation's *Settings → Personal access
   tokens* page only carries policy and approvals — **you cannot create a token there**, which is
   the other place people get stuck.

2. **Token name** — anything; `image-manager-installer` is fine.

3. **Resource owner** — select **`helloskyy-io`**.

   This is the field that points a personally-created token at the organisation. If the org does
   not appear, fine-grained tokens are disabled for it and no token you create will work — see
   *If it does not appear* below.

4. **Expiration** — up to **366 days**, which is the maximum. There is no non-expiring
   fine-grained token; **the install stops working the day it lapses**, so record the date.

5. **Repository access** — choose **Only select repositories**, then pick **`image-manager`**.

   Not *All repositories*. This box ends up on the public internet, and the token only ever needs
   to clone one repo.

6. **Permissions → expand `Repository permissions`.**

   You will see a long list — Actions, Administration, Attestations, Checks, Codespaces,
   **Contents**, Deployments, Environments, Issues, **Metadata**, Packages, Pages, Pull requests,
   Secrets, Webhooks, and more. **Every one defaults to `No access`.**

   | Permission | Set to | Why |
   |---|---|---|
   | **Contents** | **Read-only** | This is the one that grants `git clone`. |
   | **Metadata** | *(sets itself)* | Becomes Read-only automatically and greys out — mandatory once anything else is granted. |
   | *everything else* | **leave at No access** | ~18 rows. Do not touch them. |

7. **Generate token**, and copy the value — GitHub shows it exactly once.

8. **If the organisation requires approval**, the token is created in a pending state. An
   organisation owner approves it under *Organisation → Settings → Personal access tokens →
   Pending requests*. It does not work until then.

### If `helloskyy-io` does not appear as a resource owner

Fine-grained tokens are disabled for the organisation. **Do not fall back to a classic PAT** — a
classic token reaches every repository your *account* can see, across every organisation, at full
read-write-delete. That is the worst credential to place on an internet-facing box.

Say so instead: there is a deploy-key variant of this installer that trades the manual paste step
for needing no organisation policy at all.

---

## Run it

```bash
curl -fsSL https://raw.githubusercontent.com/helloskyy-io/installer/main/image-manager/bootstrap.sh | sudo bash
```

**Nothing is typed on the command line, so nothing lands in shell history.** The script asks for the
token — input hidden — and only if it actually needs one.

**It asks only when the answer to one question is no:** *is there a usable token already in the k3s
Secret?* On a fresh VM there is no cluster, so it asks. On a re-run where the stored token still
works, it does not. **A stored token that has EXPIRED counts as "no"** — presence is not validity,
and a fine-grained token dies at 366 days.

For an unattended re-run, `IMAGE_MANAGER_PAT` in the environment short-circuits the prompt — never
the check — and then `sudo -E` is required so the variable survives. **Prefer the prompt when a
human is present: an exported secret is a secret in your shell history.**

### What it does

| # | Step |
|---|---|
| 1 | Decides whether a token is needed, and asks only if it is |
| 2 | `/opt/skyy-net` and the `skyy-net` group, with a default ACL; adds the invoking user |
| 3 | `git` |
| 4 | Clones `image-manager` over HTTPS using the token |
| 5 | Hands off to `/opt/skyy-net/image-manager/bootstrap.sh` |

**No Docker. No SSH key. No Helm. No hypervisor guest agent. No manual pause.** Each is a deliberate
departure from the `skyy-command` installer beside it.

**The guest agent is the one worth explaining, because its absence is a security ruling.** A
qemu-guest-agent is a channel *from* the hypervisor *into* the guest — it can execute commands and
read the filesystem. That is defensible on a box we own and manage; **shipping it to an operator's
VM is a back door we put there.** This tier is a product other people will run, so the installer
never places one. If our own instance wants an agent for our convenience, the MDC hosting it
installs it — that is the hypervisor's business, not this product's.

**It assumes a rented VM and nothing else** — no hypervisor, no host agent, no platform underneath.
We happen to run instance zero on MDC1 because we own that hardware, but it installs the same way on
a VPS from anyone. The only environmental assumption is Debian or Ubuntu, for `apt-get`.

### What happens to the token

**It is held transiently and never comes to rest.** Read from your terminal (or the environment, if
you chose that path), held in a shell variable, gone when the process exits. It is never written to a file, never placed in the remote URL, never
left in `.git/config`, and never passed on a command line — git receives it through `GIT_ASKPASS`.
The script then **asserts** the stored remote is credential-free rather than assuming it, because a
token in `.git/config` would survive every later stage.

The durable copy is placed into a k3s Secret by stage 2, once a cluster encrypted at rest exists to
hold it.

### Re-running it

**Always safe, from any state, and you never have to work out which stage failed.**

Every task converges rather than skips — it asks *"is the end state true?"* and makes it true if
not. It never asks *"does this artifact exist?"* and step over, because that cannot repair a
half-made artifact.

**For the repository, the end state is present AND current** — not merely present. A checkout made
before the last push is a perfectly valid git repository and the wrong code, so the script fetches
and fast-forwards. **It will not destroy local work:** if the tree is dirty or HEAD has diverged, it
says so and leaves it alone for you to resolve.

A directory that exists but is not a valid repository — a clone that died mid-transfer — is removed
and re-cloned.

The same applies to the credential. The repository being present says nothing about whether a
usable token exists, so the two are decided independently.

---

## Troubleshooting

**It asks for a token when you expected it not to** — the stored one has expired, been revoked, or
lost org approval. Presence is not validity; it asked GitHub. Create a new token and paste it.

**It does not ask, and you wanted it to** — the token in the k3s Secret is still valid. To force a
replacement, delete the Secret: `kubectl -n image-manager delete secret repo-read-pat`.

**`there is no terminal to ask on`** — you piped the script somewhere with no TTY. Run it
interactively, or set `IMAGE_MANAGER_PAT` and use `sudo -E`.

**Clone fails with authentication error** — the token has not been approved by the organisation, or
`Contents` was left at *No access*, or `image-manager` was not selected under *Only select
repositories*.

**`Stage 2 not found`** — the clone worked and `image-manager/bootstrap.sh` is not in the
repository yet. Expected while stage 2 is being written; the installer stops cleanly rather than
executing a path that is not there.
