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
export IMAGE_MANAGER_PAT=github_pat_your_token_here
curl -fsSL https://raw.githubusercontent.com/helloskyy-io/installer/main/image-manager/bootstrap.sh | sudo -E bash
```

**`sudo -E` is not optional.** Without `-E`, sudo strips the environment and the token does not
reach the script. It checks for the token before doing anything, so you get an error rather than a
half-installed box.

### What it does

| # | Step |
|---|---|
| 1 | `qemu-guest-agent` — so the hypervisor can see and quiesce the VM |
| 2 | `/opt/skyy-net` and the `skyy-net` group, with a default ACL; adds the invoking user |
| 3 | `git` |
| 4 | Clones `image-manager` over HTTPS using the token |
| 5 | Hands off to `/opt/skyy-net/image-manager/bootstrap.sh` |

**No Docker. No SSH key. No Helm. No manual pause.** Each of those is a deliberate departure from
the `skyy-command` installer beside it — this tier forbids a Docker daemon outright, one token
replaces the per-repository key scheme, and stage 2 installs Helm because stage 2 is what uses it.

### What happens to the token

**It is held transiently and never comes to rest.** Read from the environment, used for one clone,
gone when the process exits. It is never written to a file, never placed in the remote URL, never
left in `.git/config`, and never passed on a command line — git receives it through `GIT_ASKPASS`.
The script then **asserts** the stored remote is credential-free rather than assuming it, because a
token in `.git/config` would survive every later stage.

The durable copy is placed into a k3s Secret by stage 2, once a cluster encrypted at rest exists to
hold it.

### Re-running it

Safe. The clone step leaves an existing checkout alone; the rest are idempotent.

---

## Troubleshooting

**`IMAGE_MANAGER_PAT is not set`** — you dropped the `-E` from `sudo -E bash`, or the export was in
a different shell.

**Clone fails with authentication error** — the token has not been approved by the organisation, or
`Contents` was left at *No access*, or `image-manager` was not selected under *Only select
repositories*.

**`Stage 2 not found`** — the clone worked and `image-manager/bootstrap.sh` is not in the
repository yet. Expected while stage 2 is being written; the installer stops cleanly rather than
executing a path that is not there.
