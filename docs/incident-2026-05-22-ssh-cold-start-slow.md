# Incident: slow SSH cold-start on the new picframe

**Date:** 2026-05-22
**Hosts:**
- New pi `ivan@10.0.0.90` — Pi Zero 2W, newer Raspberry Pi OS (Trixie-ish), OpenSSH **10.0p2**, Wayland (labwc)
- Old pi `ivan.cherednychok@10.0.0.102` — Pi Zero W, Raspbian **Buster** (deb10), OpenSSH **7.9p1**, X11
- Symptom reported on `.90`; comparison run against `.102`

**Symptom:** First SSH of the session to `.90` "feels sluggish." Subsequent SSHs are fine. Same flow against `.102` feels instant, despite weaker hardware and older OS.

---

## Summary

The first SSH after a long idle takes **~10.8s** to `.90` vs **~1.0s** to `.102`. The slowdown is **not** caused by Wayland, the picframe app, post-quantum KEX, MOTD scripts, or the newer Pi hardware. It's caused by **one rejected key offer during authentication** that the new pi's sshd takes ~9 seconds to process on a cold sshd fork, versus ~30 ms on the old pi.

Once sshd is warm (i.e. after the first connection), both pis behave similarly (~0.4–1.2s).

---

## What actually happens

`~/.ssh/authorized_keys` on both pis contains only the RSA key. The Mac client offers keys in this order (default OpenSSH preference): `id_ed25519` → `id_rsa` → others. So **every** first auth attempt looks like this:

1. Client offers `id_ed25519` (ed25519 is preferred over RSA).
2. Server checks `authorized_keys`, doesn't find it, rejects.
3. Client offers `id_rsa`, server accepts.

The bug is in step 2 on the new pi when sshd is cold.

### Verbose phase breakdown (cold, no `ControlMaster`)

| Phase | New pi `.90` (cold) | Old pi `.102` |
|---|---|---|
| TCP connect | 116 ms | ~0 ms (already cached) |
| Banner from sshd (fork+init) | 530 ms | 184 ms |
| KEX | 170 ms (`mlkem768x25519-sha256`) | 100 ms (`curve25519-sha256`) |
| Offer ed25519 → server rejects | **9020 ms** | **30 ms** |
| Offer rsa → server accepts | 6 ms | 26 ms |
| Auth complete → command → exit | 940 ms | 510 ms |
| **Total** | **~10.8s** | **~1.0s** |

The ~9-second wall is the single dominant cost. Network is fine (`.90` actually has *lower* ping latency than `.102` — 7.5 ms vs 47 ms).

### Reproducing the trace

```bash
# Force a "cold" connection: wait several minutes since last SSH to the host.
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

Look for a big gap between two consecutive `Offering public key:` lines. That gap = server-side time to reject a key.

---

## Why the new pi takes 9 seconds and the old pi takes 30 ms

Same connection flow, same key rejection — but the cost is ~300× higher on the new pi from a cold sshd fork. Several factors compound:

1. **OpenSSH 10.0p2 vs 7.9p1.** Newer sshd ships with more code paths active by default (`UsePAM yes` more involved, more PAM modules, more session/security checks). Each one has to be loaded from disk on the first fork.
2. **Newer OS PAM stack.** Trixie/Bookworm defaults pull in more modules (e.g. `pam_faillock`, `pam_systemd`, `pam_env` chains) than Buster did. The first failed auth triggers the whole stack to load and run.
3. **systemd-logind.** Newer setup; the first session creates D-Bus traffic and writes a session record. Cold, this is multiple disk seeks.
4. **journal/auth.log cold writes.** First auth event of the day flushes a binary journal entry; that's a real fsync on SD card storage.
5. **Pi Zero 2W governor.** `ondemand` idles at ~600 MHz. Bursty work like sshd auth doesn't keep the CPU at max long enough to ramp; it stays in low-power mode through these short bursts.
6. **SD-card cold-cache I/O.** The biggest factor. None of the above is cached in RAM after long idle. Once sshd's binary, libpam shared objects, journal fd, and auth.log are paged in, subsequent connections fly.

All of these are *not* configuration bugs — they're the cumulative cost of "more modern OS on the same anemic SD card and CPU." The old pi avoids most of it by simply having less machinery to load.

Not directly tested, but possible contributors that would deserve a look if the fix below ever stops working: swap pressure (Pi Zero 2W has only 512 MB RAM, and a fresh Trixie can run close to that), `zram` config differences, or third-party modules (fail2ban, etc.) hooked into sshd.

---

## Fix

**Two layers, both applied. Either alone would resolve the symptom; together they're defense in depth.**

### 1. Client side — never offer a key the server won't accept

`~/.ssh/config` on the Mac:

```
Host 10.0.0.90
  User ivan
  IdentitiesOnly yes
  IdentityFile ~/.ssh/id_rsa

Host 10.0.0.102
  User ivan.cherednychok
  IdentitiesOnly yes
  IdentityFile ~/.ssh/id_rsa
```

`IdentitiesOnly yes` tells ssh to offer **only** the listed identity file and ignore everything else loaded in `ssh-agent`. The rejected ed25519 offer never happens, so the 9s server-side cost never occurs.

Expected cold time after this change: ~1.5s on `.90`, ~1.0s on `.102`.

### 2. Server side — accept whatever the client offers first

Add every Mac public key to each pi's `~/.ssh/authorized_keys` so no key offer is ever rejected:

```bash
# Run from the Mac, once per pi. This appends to authorized_keys, doesn't replace.
ssh-copy-id -i ~/.ssh/id_ed25519.pub ivan@10.0.0.90
ssh-copy-id -i ~/.ssh/id_rsa.pub     ivan@10.0.0.90    # idempotent if already there
ssh-copy-id -i ~/.ssh/id_ed25519.pub ivan.cherednychok@10.0.0.102
```

This is a change to user data (`~/.ssh/authorized_keys`), not to system config.

---

## How to spot this kind of regression in the future

A 9-second SSH stall that disappears on retry and only happens on cold start is almost always:

1. A failed auth attempt the client is making without knowing, **or**
2. Reverse DNS / GSSAPI timeout on the server.

Both look identical in user-perceived behavior. Both are diagnosed by `ssh -vv` with a per-line timestamper. Look for the largest `+Xms` gap in the trace and the phase it's between.

If the gap is between two `Offering public key:` lines → it's #1 above (this incident).
If it's right after the banner, before KEX, or before the first auth method → it's #2 (set `UseDNS no` / `GSSAPIAuthentication no` on the server, or `-o GSSAPIAuthentication=no` from the client).
