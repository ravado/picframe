# Incident: slow SSH cold-start on the new picframes

**Date:** 2026-05-22 (initial investigation), updated 2026-05-23 with corrected breakdown
**Hosts:**
- New pis (Trixie-ish, OpenSSH **10.0p2**, Wayland/labwc, Pi Zero 2W):
  - `ivan@10.0.0.90`
  - `ivan@10.0.0.91`
  - `ivan@10.0.0.92` (offline during this investigation)
- Old pi `ivan.cherednychok@10.0.0.102` — Pi Zero W, Raspbian **Buster** (deb10), OpenSSH **7.9p1**, X11 — used as the fast-baseline reference

**Symptom:** First SSH of the session to any new pi "feels sluggish" (≈10s). Subsequent SSHs are fine (<1s). Same flow against `.102` feels instant (~1s) every time, despite weaker hardware and older OS.

---

## Summary

The original ~10.8s cold time on `.90` decomposes into **two** independent server-side costs, not one:

1. **~6 seconds** for sshd to reject an offered key that isn't in `authorized_keys`. The Mac client offers `id_ed25519` first by default; neither pi has that key in `authorized_keys`, so it gets rejected. On a cold sshd fork on the new pi this rejection takes ~6s. On the old pi it takes ~30 ms.
2. **~4.5 seconds** of cold PAM + disk + session-setup cost that hits **any** auth attempt regardless of which key is used. This is the cumulative cost of cold-paging libpam modules, `pam_systemd`, journal/auth.log fsyncs, and the public-key crypto verification on a Pi Zero 2W CPU still ramping up from idle.

The client-side fix (`IdentitiesOnly yes` + `IdentityFile ~/.ssh/id_rsa`) removes cost #1. Measured result: cold dropped from **10.8s → 4.93s** on `.90`. Cold on `.91` (first-ever connection, never seen by the client before either) measured **7.0s**.

Cost #2 is structural — newer Debian PAM stack running on slow SD-card storage. No client-side config fully eliminates it. The practical workaround is `ControlMaster` so the cold cost is paid at most once per multiplex window, not per-command.

Once sshd is warm (i.e. after the first successful auth), all new pis behave like the old one (~0.4–1.2s).

---

## What actually happens

`~/.ssh/authorized_keys` on every pi contains only the RSA key. The Mac client offers keys in this order (default OpenSSH preference): `id_ed25519` → `id_rsa` → others.

### Original cold trace, no client config (2026-05-22)

| Phase | New pi `.90` (cold) | Old pi `.102` |
|---|---|---|
| TCP connect | 116 ms | ~0 ms (already cached) |
| Banner from sshd (fork+init) | 530 ms | 184 ms |
| KEX | 170 ms (`mlkem768x25519-sha256`) | 100 ms (`curve25519-sha256`) |
| **Offer ed25519 → server rejects** | **9020 ms** | 30 ms |
| Offer rsa → server accepts | 6 ms | 26 ms |
| Auth complete → command → exit | 940 ms | 510 ms |
| **Total** | **~10.8s** | **~1.0s** |

The 9020 ms gap was misread initially as "rejection cost only." A follow-up trace after applying the client-side fix showed the real split.

### Cold trace after client config (2026-05-23)

`~/.ssh/config` now forces `IdentitiesOnly yes` + `IdentityFile ~/.ssh/id_rsa` for the picframes, so the ed25519 offer is skipped entirely. The remaining cold time:

| Phase | New pi `.90` (cold, no rejection) |
|---|---|
| TCP → banner | 73 ms |
| KEXINIT exchange | 74 ms |
| KEX + host key verify | 60 ms |
| service-accept (ssh-userauth) | 70 ms |
| **Offer rsa → server accepts (cold PAM auth-stack + pubkey verify)** | **2680 ms** |
| **Accept → Authenticated (`pam_acct_mgmt` + `pam_session_open` + journal write)** | **1854 ms** |
| Send env + exit | 165 ms |
| **Total** | **~4.97s** |

So the 9020 ms "rejection gap" was really `~6s extra rejection cost + ~3s of the same cold PAM/journal cost that now appears on the accepted path instead`. Both costs were present originally; the rejection just inflated the visible number.

Network is not the cause anywhere — `.90` actually has *lower* ping than `.102` (7.5 ms vs 47 ms).

### Reproducing the trace

```bash
# Force a "cold" connection: wait ~5-6 minutes since the last SSH to the host.
# Add a per-line timestamp so phase gaps are visible:
cat > /tmp/sshtime.py <<'EOF'
import sys, time
t0 = prev = None
for line in sys.stdin:
    now = time.time()
    if t0 is None: t0 = prev = now
    sys.stdout.write(f"[{now-t0:6.3f}s +{(now-prev)*1000:7.1f}ms] {line}")
    sys.stdout.flush()
    prev = now
EOF

ssh -vv -o ControlMaster=no -o ControlPath=none ivan@10.0.0.90 exit \
  | python3 /tmp/sshtime.py
```

Look for the largest `+Xms` gap. Where it sits maps to the cause:

- Between two `Offering public key:` lines → a rejected key offer (cost #1 above).
- Between `Offering public key:` and `Server accepts key:` → cold pubkey verify + PAM auth stack (cost #2, part A).
- Between `Server accepts key:` and `Authenticated to ...` → cold PAM account/session modules + journal fsync (cost #2, part B).
- Right after the banner (before KEX) → reverse DNS / GSSAPI timeout (not this incident, but the other classic cause).

---

## Why the new pi is so much heavier than the old one

Same connection flow, vastly different cost on cold sshd fork. Contributing factors:

1. **OpenSSH 10.0p2 vs 7.9p1.** Newer sshd ships with more code paths active by default, including post-quantum KEX and a larger default PAM integration.
2. **Newer OS PAM stack.** Trixie/Bookworm defaults pull in more modules (e.g. `pam_faillock`, `pam_systemd`, `pam_env` chains) than Buster did. Every cold auth attempt — successful or not — has to load all of them.
3. **systemd-logind.** Newer setup; the first session creates D-Bus traffic and writes a session record. Cold, this is multiple disk seeks.
4. **journal/auth.log cold writes.** First auth event of the day flushes a binary journal entry; that's a real fsync on SD-card storage.
5. **Pi Zero 2W governor.** `ondemand` idles at ~600 MHz. Bursty work like sshd auth doesn't sustain enough load to ramp; it stays in low-power mode through these short bursts.
6. **SD-card cold-cache I/O.** Dominant factor. None of the above is cached in RAM after long idle. Once sshd's binary, libpam shared objects, journal fd, and auth.log are paged in, subsequent connections fly.

All of these are *not* configuration bugs — they're the cumulative cost of "more modern OS on the same anemic SD card and CPU." The old pi avoids most of it by simply having less machinery to load.

Not yet measured (would need read-only checks on the pi: `free -h`, `swapon --show`, `vmstat 1 5`, `journalctl _COMM=sshd -n 50`, `cat /etc/pam.d/sshd`): whether swap is being touched, and which specific PAM modules are slowest to load. Pi Zero 2W has only 512 MB RAM and a fresh Trixie can run close to that, so swap is plausible.

---

## Fixes — what's applied, what's available

### 1. Client config — applied 2026-05-23

`~/.ssh/config` on the Mac now contains:

```
# Picframes — force RSA-only to avoid 6s server-side hang on rejected ed25519 offer.
Host 10.0.0.90 10.0.0.91 10.0.0.92
  User ivan
  IdentitiesOnly yes
  IdentityFile ~/.ssh/id_rsa
```

Effect: removes the rejected-key cost (~6s on cold). Measured cold result: **10.8s → 4.93s** on `.90`. Warm unchanged.

### 2. Server-side authorized_keys — optional, not required if (1) is in place

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub ivan@10.0.0.90
ssh-copy-id -i ~/.ssh/id_ed25519.pub ivan@10.0.0.91
# ...
```

Achieves the same outcome as (1) by a different path: every key offer succeeds, so no rejection ever happens. Defense in depth — useful if you ever connect from another machine without that `~/.ssh/config` block.

### 3. `ControlMaster` — recommended next step to make cost #2 disappear in practice

The remaining ~4.5s cold cost can't be eliminated client-side, but it can be made invisible by reusing a multiplexed connection. Add to `~/.ssh/config`:

```
Host 10.0.0.90 10.0.0.91 10.0.0.92
  ControlMaster auto
  ControlPath ~/.ssh/cm/%h-%p-%r
  ControlPersist 10m
```

Then `mkdir -p ~/.ssh/cm && chmod 700 ~/.ssh/cm`.

Effect: first ssh of the window pays the ~5s cold cost. Every subsequent ssh/scp/rsync to the same host within 10 minutes reuses the live connection and starts in <100 ms. Doesn't help the very-first SSH of a long-idle session — that's a hardware/OS issue.

Not yet applied. Decide before adding.

### 4. Server-side PAM trim — only if (3) isn't enough

Disabling `pam_faillock`/`pam_systemd` lines in `/etc/pam.d/sshd` on the pi would likely cut the ~1.85s "accept → authenticated" gap. Real OS config change with security implications (e.g. removing failed-login lockout). Don't do without an explicit decision.

### 5. Hardware — root cause fix

USB SSD boot instead of SD card. Largest impact on cold cost. Not in scope here.

---

## How to spot this kind of regression in the future

A multi-second SSH stall that disappears on retry and only happens on cold start is almost always one of:

1. A failed auth attempt the client is making without knowing (this incident — cost #1).
2. Cold PAM/journal/disk on a heavy modern OS running on slow storage (this incident — cost #2).
3. Reverse DNS / GSSAPI timeout on the server (classic but unrelated here).

All three look identical to a user. All three are diagnosed by `ssh -vv` with a per-line timestamper. Look for the largest `+Xms` gap and the phase it sits between (see "Reproducing the trace" above).

For #3 specifically: set `UseDNS no` / `GSSAPIAuthentication no` on the server, or `-o GSSAPIAuthentication=no` from the client.
