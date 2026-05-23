# Migration Plan: GitHub → Forgejo (LAN)

## Context

The picframe-custom fork currently lives on GitHub at `git@github.com:ravado/picframe.git`. We are moving to a self-hosted Forgejo instance at `git.at.home` (planned future hostname: `git.cherednychok.uk`). Drivers: ownership of the infrastructure, LAN-first deployment model, and consolidation with the other self-hosted services (NAS, fluent-bit → Loki).

The upstream `helgeerbe/picframe` will be pull-mirrored under a dedicated `mirrors/` namespace so the fork can keep tracking it for rebases without depending on GitHub at runtime. Deployed frames reach the LAN via WireGuard, so they can talk to Forgejo from any location — no public exposure of Forgejo is required for this migration.

## Complexity rating: **Medium-Low (3 / 5)**

- All code edits are mechanical URL swaps — no logic changes, no schema changes, no breaking API moves.
- Roughly ten active script lines to rewrite, plus optional documentation cleanup.
- Risk concentrates in the **deployed-frame switchover**: SSH host-key trust, deploy-key registration on Forgejo, and DNS / WG reachability. Each frame must be touched once over SSH.
- Reversible: the GitHub remote can be re-added at any time if something goes wrong.

## Decisions

| Topic | Decision |
|---|---|
| Forgejo host | `git.at.home` now, planned future `git.cherednychok.uk` — parameterize where practical |
| Namespaces | `mirrors/picframe` (upstream auto-sync), `ravado/picframe` (the fork) |
| Frame auth | SSH key (deploy key per frame) |
| Frame reachability | WireGuard tunnel — already in place |
| Upstream tracking | Forgejo pull-mirror, auto-sync |
| GitHub fate | Push-mirror as optional backup (Forgejo → GitHub, one-way) |
| 3rd-party binary downloads (node_exporter, promtail) | Leave on GitHub — external projects, frames can hit them over WG |

## Forgejo-side setup (do first, before touching any code)

Done in the Forgejo web UI / admin panel.

1. **Create namespace `mirrors`** (organization or user). Repo: `mirrors/picframe`.
   - Type: **Migration → Mirror**. Source URL: `https://github.com/helgeerbe/picframe.git`. Tick **Mirror this repository** (pull-mirror). A 24-hour sync interval is sufficient.
2. **Create repo `ravado/picframe`**.
   - Type: **Migration**. Source URL: `https://github.com/ravado/picframe.git`. **Do not** tick mirror — this needs to be a fully writable fork. Include LFS, releases, wiki, and issues if relevant.
   - Default branch: `develop` (matches the existing repo).
3. **(Optional) Push-mirror back to GitHub.**
   - In `ravado/picframe` → Settings → Mirror Settings → **Add push-mirror**. Target: `https://github.com/ravado/picframe.git`. Auth: a GitHub fine-grained PAT with `contents:write` on that repo. Tick **on commit**. Reversible at any time.
4. **Register one deploy key per frame.**
   - `ravado/picframe` → Settings → Deploy Keys → Add. Use the existing `~/.ssh/id_*.pub` from each frame (the keys already trusted by GitHub). Mark **read-only** unless a frame ever needs to push (it does not).

## Files that must change (active / break-on-migration)

These are the URLs invoked at install / runtime. Rewriting them is the migration.

| File | Line | Current | New |
|---|---|---|---|
| `scripts/install/2_install_picframe.sh` | 11 | `REPO_URL="https://github.com/ravado/picframe.git"` | `REPO_URL="${REPO_URL:-git@git.at.home:ravado/picframe.git}"` |
| `scripts/install/install_all.sh` | 4 | `REPO_URL="https://raw.githubusercontent.com/ravado/picframe/main/scripts/install"` | `REPO_URL="${REPO_URL:-https://git.at.home/ravado/picframe/raw/branch/develop/scripts/install}"` |
| `scripts/install/configure_periodic_backups.sh` | 4 | `BACKUP_URL="https://raw.githubusercontent.com/ravado/picframe/refs/heads/main/scripts/install/0_backup_setup.sh"` | `BACKUP_URL="${BACKUP_URL:-https://git.at.home/ravado/picframe/raw/branch/develop/scripts/install/0_backup_setup.sh}"` |
| `scripts/install/README.md` | 77 | `bash <(curl -fsSL https://raw.githubusercontent.com/ravado/picframe/main/scripts/install/install_all.sh)` | `bash <(curl -fsSL https://git.at.home/ravado/picframe/raw/branch/develop/scripts/install/install_all.sh)` |
| `scripts/monitoring/README.md` | 17 | `…raw.githubusercontent.com/ravado/picframe/refs/heads/main/scripts/monitoring/install_fluentbit_and_node_exporter.sh` | `https://git.at.home/ravado/picframe/raw/branch/develop/scripts/monitoring/install_fluentbit_and_node_exporter.sh` |
| `scripts/monitoring/README.md` | 36 | `…install_alloy.sh` | `https://git.at.home/ravado/picframe/raw/branch/develop/scripts/monitoring/install_alloy.sh` |
| `scripts/monitoring/install_alloy.sh` | (curl line for `default_config.alloy`) | `…raw.githubusercontent.com/ravado/picframe/refs/heads/main/scripts/monitoring/default_config.alloy` | `https://git.at.home/ravado/picframe/raw/branch/develop/scripts/monitoring/default_config.alloy` |

Notes
- Forgejo raw-content URL pattern: `https://<host>/<owner>/<repo>/raw/branch/<branch>/<path>`.
- All `main` → `develop` (this repo's default branch is `develop`; the GitHub URLs that referenced `main` were stale and likely 404'd already).
- Use `${VAR:-default}` so a future hostname migration is just `FORGEJO_HOST=git.cherednychok.uk` at the call site. Alternatively, introduce a single `FORGEJO_BASE` env var sourced from `install/env_loader.sh`.

## Files that should change (informational, no runtime impact)

| File | Change |
|---|---|
| `pyproject.toml:66` | `"Homepage" = "https://github.com/helgeerbe/picframe"` — either leave (upstream attribution) or point to `https://git.at.home/ravado/picframe`. Recommendation: **leave** — the package is internal-only, metadata does not matter, and `helgeerbe/picframe` is the original. |
| `README.md` (lines 3, 16, 23, 51, 60, 64, 68) | All point to upstream helgeerbe or external projects (pi3d, glenvorel). Leave as-is — they are correct external attribution. |
| `AGENTS.md` (lines 3, 118) | Replace `git@github.com:ravado/picframe.git` with `git@git.at.home:ravado/picframe.git`; update fork link to Forgejo. |
| `.claude/CLAUDE.md` (project-local, **not** global) | Same as AGENTS.md — update the **Remote** line to Forgejo. |
| `docs/plans/task-001.md` and `.claude/plans/task-001.md` | Historical; leave as-is. |
| `versioneer.py` | Auto-generated tooling references — leave. |

## Deployed frames: per-frame migration steps

Run **once per frame** (`home`, `batanovs`, `cherednychoks`). Frames must already be on the WG tunnel; verify with `ping git.at.home` first.

```bash
# 1. Verify reachability
ssh ivan@<frame>
ping -c 2 git.at.home

# 2. Trust the Forgejo SSH host key (one-time per frame)
ssh-keyscan -t ed25519,rsa git.at.home >> ~/.ssh/known_hosts

# 3. Confirm SSH auth works
ssh -T git@git.at.home   # expect "Hi <user>! You've successfully authenticated..."

# 4. Switch the remote
cd ~/picframe
git remote set-url origin git@git.at.home:ravado/picframe.git
git remote -v   # verify

# 5. Pull to confirm
git fetch origin
git pull --ff-only

# 6. Run the standard update path end-to-end
~/picframe/scripts/ops/update.sh
```

If a frame's SSH public key was not added to the Forgejo deploy keys in setup step 4, step 3 will fail with `Permission denied (publickey)`. Grab the key with `cat ~/.ssh/id_*.pub` over SSH and paste it into Forgejo.

**DNS note:** `git.at.home` must resolve from the frame. Confirm via `getent hosts git.at.home`. If the WG tunnel does not push DNS, fall back to a one-line `/etc/hosts` entry on each frame, or set up systemd-resolved with a search-domain rule.

## Migration sequence

1. **Forgejo setup** (web UI) — mirror + fork repos, push-mirror to GitHub if desired, register deploy keys.
2. **Make code changes** on a branch in the local working copy (`scripts/install/*.sh`, `scripts/monitoring/*`, READMEs, `AGENTS.md`, `.claude/CLAUDE.md`).
3. **Push to both remotes** while testing: keep `origin` on GitHub, add a `forgejo` remote, push to both. Verify Forgejo URLs resolve and raw downloads return HTTP 200.
4. **Switch the home frame first** (lowest risk, you can fix in person). Run the per-frame migration steps. Run `ops/update.sh`. Confirm `picframe.service` restarts cleanly.
5. **Switch remote frames** (batanovs, cherednychoks) over SSH/WG.
6. **Flip primary remote** in the local working copy: `git remote set-url origin git@git.at.home:ravado/picframe.git`. Keep `github` as a secondary push remote if belt-and-braces is desired.

## Rollback

Per-frame: `git remote set-url origin git@github.com:ravado/picframe.git` — instant revert.
Repo-wide: keep the GitHub repo as a push-mirror target during the transition window (for example, 30 days); if Forgejo proves unreliable, stop the push-mirror and re-flip remotes. No data loss is possible because GitHub is being mirrored *to*, not deleted.

## Verification checklist

- [ ] `mirrors/picframe` on Forgejo shows recent commits from helgeerbe (auto-sync working)
- [ ] `ravado/picframe` on Forgejo has all branches/tags from GitHub (`git ls-remote` counts match)
- [ ] `curl -fsSI https://git.at.home/ravado/picframe/raw/branch/develop/scripts/install/install_all.sh` returns 200
- [ ] From a frame: `ping git.at.home` succeeds
- [ ] From a frame: `ssh -T git@git.at.home` authenticates
- [ ] From a frame: `git pull` succeeds after the remote swap
- [ ] `ops/update.sh` completes end-to-end on each frame; `picframe.service` restarts and runs
- [ ] (Optional) Push-mirror to GitHub: make a no-op commit on Forgejo, confirm it appears on GitHub within a minute

## Open items / future-proofing

- **`FORGEJO_HOST` env-var convention.** Adding a one-line `FORGEJO_HOST` knob (defaulting to `git.at.home`) in `install/env_loader.sh` would make the `git.at.home` → `git.cherednychok.uk` switch a single-file edit later. Recommended but optional.
- **Forgejo SSH host key change.** If the Forgejo host key is regenerated during a future server rebuild, frames will refuse to connect until `known_hosts` is updated. Worth a follow-up snippet such as `manage.sh trust-forgejo`.
- **Public-readable upstream mirror.** When `git.cherednychok.uk` goes public, decide whether `mirrors/picframe` stays private or becomes a public attribution mirror.
