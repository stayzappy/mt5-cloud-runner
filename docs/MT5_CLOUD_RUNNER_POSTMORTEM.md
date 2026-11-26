# MT5 Cloud Runner Incident Postmortem & Runbook

**Date:** 2026-11-24
**Incident:** 4-account headless MT5 fleet offline on GitHub Actions for ~5 days (all previous fix attempts failed)
**Status:** RESOLVED — all 4 accounts ONLINE on the cloud runner, verified with live balances
**Repos:** `stayzappy/mt5-cloud-runner` (harness), `stayzappy/mt5-forex-bot` (engine)

---

## 1. Executive Summary

The cloud fleet failed because the upstream Docker image `lprett/mt5linux:mt5-installed`
was republished with an **old MT5 terminal build (5616)**. MetaTrader brokers (Exness)
now reject that build at authorization: `authorization on Exness-MT5Real21 failed (Old version)`.
The terminal self-updates via LiveUpdate to build 6230 several minutes into its first boot,
but every harness version in circulation injected the account profiles ~30 seconds after
container start — **while the terminal was still mid-update**. The running old terminal then
deleted the injected account state (`Accounts deleted due old version`) and the terminal
could never authorize again, producing the persistent `-6 'Terminal: Authorization failed'`
(and earlier, `-10005 'IPC timeout'`) on all 4 accounts.

The fix reorders the bring-up: **wait for the terminal's cold first-boot + LiveUpdate to
complete, THEN inject profiles, then verify with a real MT5-level readiness gate** — with
self-healing retry cycles. No file uploads are required; the profiles already in the repo
are sufficient.

---

## 2. Symptoms (what was observed)

- Cloud runs: `docker compose` starts, containers come up, RPyC TCP socket on 18812 opens
  (the `mt5linux` bridge starts independent of the terminal).
- `mt5.initialize()` across the bridge fails on all 4 accounts:
  - Initially: `(-10005, 'IPC timeout')` / `(-10003, "Pipe server didn't answer in 60 sec")`
  - After harness iterations: `(-6, 'Terminal: Authorization failed')`
- Worker telemetry: all accounts `state: FAULT`, `is_connected: null`.
- Telegram spam: `SYSTEM FAULT DETECTED [CRITICAL] / ACCOUNT_INFO_UNAVAILABLE`
  (caused by `notify_fault()` reading `fault_alerts: true` synced from the Worker,
  overriding the local `False` default — fixed in `mt5-forex-bot` commit `44802ef`).
- The same account profiles/credentials worked 100% on the local machine for 2 months.

---

## 3. How the diagnosis was done (methodology — reuse this)

Do NOT blind-patch the harness. Isolate the variable by reproducing the cloud flow
locally with throwaway probe containers:

```bash
# reproduce the cloud cold boot on the current upstream image
docker run -d --name mt5_probe lprett/mt5linux:mt5-installed
docker exec mt5_probe sh -c 'ls -t "/opt/wineprefix/drive_c/Program Files/MetaTrader 5/logs/"*.log | head -1'
# read the MT5 terminal log (UTF-16LE! strip NULs):
docker exec mt5_probe sh -c 'cat "<log>" | tr -d "\000"'
# run the exact MT5-level check inside the container:
docker exec mt5_probe sh -c 'cd /mt5linux && wine python -c "import MetaTrader5 as m; print(m.initialize(), m.last_error())"'
```

The MT5 terminal log was the single most valuable source — it showed
`Accounts deleted due old version` and `authorization ... failed (Old version)`,
which no amount of harness tweaking could reveal.

### Key experiments (all on the local machine, current upstream image)

| Probe | Flow | Result |
|---|---|---|
| probe1 | boot → wait for first-boot (LiveUpdate) to COMPLETE → inject profiles → restart | **SUCCESS** (`initialize: True`, account 161806031, balance 2828) |
| probe2 | inject profiles at T+15s + restart (cloud-like timing) | **FAILED** — accounts deleted, stuck at `-6` forever |
| probe3 | inject "modern build 6328" tarball exe instead | **FAILED** — that build doesn't pair with metatrader5 5.0.5572 |
| probe4 | full fixed sequence end-to-end | **PASSED** deep gate: `True (1, 'Success') (161806031, 'Exness-MT5Real21', 2828.0)` |
| probe5 | detection-logic unit check | Caught a false-positive (stale image log + `Windows 10 build 19043` regex collision) |

Also verified: `metatrader5 5.0.5572` + `mt5linux 1.0.3` are identical in old/new images;
the only relevant image change is the terminal binary.

---

## 4. Root Cause Chain (evidence-based)

1. `docker image inspect lprett/mt5linux:mt5-installed`:
   - Local (working, 2 months): digest `sha256:aed2db8e...` — terminal build 6230 baked in.
   - Upstream now: digest `sha256:40480bc9...` — **build 5616** (140,701,408 bytes).
   - The old digest is **deleted from Docker Hub** (`not found` when pulling by digest) —
     repinning is not an option.
2. Broker enforcement: fresh 5616 terminal →
   `Network '161806031': authorization on Exness-MT5Real21 failed (Old version)`.
   (Local 6230 terminals authorize fine; the minimum enforced build is between 5616–6230.)
3. First-boot behavior: terminal runs `Full recompilation` → LiveUpdate downloads
   build 6230 (~4-20 min depending on machine) → relaunches.
4. Harness bug: injection + `docker restart` happened ~30-40s after `docker compose up -d`
   (mid-update). The old terminal read the injected `accounts.dat` (6230 format) →
   `Accounts deleted due old version` → after the interrupted update the terminal had no
   account to reconnect → `initialize()` → `-6` permanently.
5. Secondary: the previous "successful" scheduled runs were **false positives** — the fleet
   exited with everything OFFLINE (`[Window Mode] All fleet accounts reached exit window`)
   and the workflow "succeeded" (exit 0).

---

## 5. The Fix (commits on `stayzappy/mt5-cloud-runner`, branch `main`)

`scripts/cloud_start_harness.sh` was restructured into **self-healing readiness cycles**
(up to 3 cycles):

1. **Wait** (per cycle): poll all containers *in parallel* (one 600s deadline) for the
   terminal's cold first-boot to complete. Detection reads **today's log only**
   (the image ships a stale log from its build day) and NUL-strips UTF-16LE:
   ready when either ≥2 `successfully initialized` boot lines, or a terminal line matching
   `MetaTrader 5 ... build >= 6000` (regex anchored to exclude `Windows 10 build 19043`).
2. **Inject** (per cycle, unchanged content + additions): profiles `Config/`, broker
   `Bases/`, `AppData/` Roaming, `user.reg`/`system.reg` (IPC parity), and `mt5cfg.ini`
   with Worker credentials via `docker exec -i` stdin; then `docker restart`.
3. **Deep MT5 gate** (per cycle): through each container's RPyC bridge
   (`rpyc.classic.connect(127.0.0.1, 18812)` → `MetaTrader5.initialize()` +
   `account_info()` login match), up to 12 attempts. On failure it dumps diagnostics
   (process list, mt5cfg.ini, terminal log tail, container logs) into
   `logs/deep_gate_<cycle>.log` and the cycle retries — a slow runner LiveUpdate
   self-heals instead of permanently deleting the injected accounts.
4. **Fail loudly**: if no cycle reaches `ALL_CONTAINERS_READY`, the run exits non-zero
   (so it can never again silently "succeed" while offline).

Commits: `baf592b` (wait + gate) → `801ae4d` (parallelize + build-number detection)
→ `f79889d` (stdin staging of the gate probe) → `2839e6e` (self-healing cycles + registry
injection + tighter gate bound).

`mt5-forex-bot` commit `44802ef` permanently silences `notify_fault`/`notify_recovery`
(Worker-synced `fault_alerts: true` was overriding the local `False` and spamming Telegram).

---

## 6. Verification

Cloud run `45386245834` (workflow_dispatch, continuous mode):

| Account | State | Live balance (from MT5 via Worker) |
|---|---|---|
| personal_cent (161806031) | ONLINE | ¢2,828 |
| personal_cent_seyi (161808780) | ONLINE | ¢1,570 |
| funded_500k (476871582) | ONLINE | ₦475,785 |
| aiwacapital_974530 (974530) | ONLINE | $10,000 |

Stable for 23+ minutes at time of writing, no faults, Telegram silent.

**Note on aiwacapital:** the Worker record (login 974530, AiwaCapital-Server, $10k
challenge) is the correct, current account per the user. An older account
(477325375, ~₦187,754 NGN) was previously loaded in the local container and is no
longer used.

---

## 7. Rules for Future Agents (from this incident)

1. **Reproduce before fixing.** Spin up a local probe container from the same image and
   replicate the cloud flow minute-by-minute. Local probes took 5 minutes each and were
   decisive; 5 days of blind harness edits were not.
2. **Read the MT5 terminal log first.** `…/MetaTrader 5/logs/<today>.log` —
   UTF-16LE (strip NULs with `tr -d "\000"`). It contains the ground truth:
   `authorization ... failed (Old version)`, `Accounts deleted due old version`, etc.
3. **Check upstream image digests when "it worked yesterday".**
   `docker image inspect lprett/mt5linux:mt5-installed` vs a known-good digest.
   A republished image (build swap) is invisible in git history.
4. **Never trust a green checkmark that didn't trade.** Verify `is_connected`/balances in
   Worker telemetry, not just workflow exit codes.
5. **Gates must test the real thing.** The old TCP-socket probe passed while the MT5
   terminal was dead. Gate on `initialize()` + `account_info()` through the actual RPyC
   bridge, and dump diagnostics on failure.
6. **Injection timing is a correctness issue, not a niceness.** MT5 first-boot does a
   LiveUpdate that relaunches the terminal; injecting profiles mid-update corrupts state
   permanently (`Accounts deleted due old version`).
7. Keep connection/startup failures silent on Telegram (user directive: fault alerts
   are permanently disabled; only genuine trade events notify).

---

---

## 10. Addendum — Nov 26 dual-pair (Gold + GBPJPY) rollout

**What shipped:** the fleet now trades Gold (32 setups) **and GBPJPY (42 setups)** on all
4 accounts under the Sweet Spot 1 governor (5 trades/week account-wide, 1/day/pair,
pair-isolated 2-win cashout / 2-loss weekly bench, max 1 open position per pair).

**Engine** (`mt5-forex-bot`, merge `9673380`):
- `src/pair_context.py`: per-pair broker identity (symbol, magic +100 offset, pip
  geometry, spread guard gj <= 2.8 pips, per-pair break-even; gj keeps ZERO_BE for
  backtest parity).
- `risk_manager.py`: `_sweet_spot_1_gate` — ledger-derived per-pair weekly/daily stats
  (restart-safe); all account-level protections unchanged.
- `fleet_runner.py`: dual-stream scanner (gold + GBPJPY per M15 close), per-symbol
  candle dedup, per-symbol active positions.
- `trade_executor.py`: position management partitioned by (magic, symbol); post-fill
  verification (repairs or closes mis-sized/un-bracketed fills).
- Config-gated per account via `ACTIVE_STRATEGY=DUAL_PLETHORA`; gold-only accounts
  keep their exact behavior.

**Validation gates passed:** 118 unit tests; offline engine-vs-ledger parity replay
(84% governed signal match, identical 1.54 trades/week cadence — residual drift
documented); local dry-run rehearsal on all 4 accounts (caught and fixed a GBPJPY
stream symbol-binding bug before release); released-binary smoke test.

**Cloud cutover lever:** `config/dual_pair_accounts.json` in this repo + an additive
harness section switch listed accounts to DUAL_PLETHORA at session start. Delete or
empty the file to revert all accounts to gold-only at the next session.

**Known residuals:** the 42-setup GBPJPY suite's OOS win rate is OOS-selection
conditioned; live planning band is 60-66% WR. The pair-isolated 2L stop bounds a bad
GBPJPY regime at -1R that pair per week (worst week -3R).

## 8. Current State / Follow-ups

- Cloud fleet is the sole runner (continuous mode). The scheduled cron workflow will
  keep launching sessions in window mode with the same hardened harness.
- Local workstation containers may be stopped when convenient (mission end-state).
- No outstanding code changes required. If the upstream image changes again, this
  postmortem's probe methodology (section 3) will pinpoint it in minutes.

---

## 9. Addendum — Nov 25 mid-session stop (infrastructure timeout, not the bot)

**What happened:** the scheduled 05:25 UTC session was trading healthily — heartbeats
with live balances and M15 bar-close logs at 12:15 WAT — when the job was cancelled at
**12:16:10 WAT**, exactly `timeout-minutes: 350` (5h50m) after start. GitHub then killed
the fleet. The 10:45 UTC scheduled run never appeared (GitHub cron delays/skips are
documented and visible in this repo's own history — the 05:00 cron fired 25 min late the
same day), so nothing replaced the session until a manual dispatch at 12:30 WAT, which
cold-booted (~14 min) and reconnected. ~14-minute outage, zero bot errors.

**Hardening shipped** (commit `c26ca0d`):
- `.github/workflows/fleet_watchdog.yml` + `scripts/fleet_watchdog.sh`: every 15 min it
  checks Worker telemetry and dispatches a replacement session **only** when the fleet is
  verifiably DOWN *and* no healthy session exists — never while a run is cold-booting
  (< 40 min old), never outside the 00:15-17:30 WAT window/weekends, never when the
  Worker API is unreachable. Zombie runs (active > 40 min with the fleet down) are
  replaced through the existing concurrency group. Verified live: "Fleet ONLINE.
  Standby." on the healthy fleet.

**Known behavior to expect (not bugs):**
- Each session handoff (cron boundary, timeout boundary, watchdog replacement) costs a
  ~14-minute cold-boot gap. The window is inherent to ephemeral GitHub runners + the
  image's first-boot LiveUpdate.
- Engine Telegram alerts are limited to genuine trade/session events
  (`notify_fault`/`notify_recovery` are permanently disabled). An "error"-looking alert
  during an outage is most likely a trade-close (❌) or the Control Studio's offline
  notification, not a fault alert from the engine.