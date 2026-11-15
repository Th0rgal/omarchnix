# Status-bar pending approvals

The existing `omarchy-orb-agent usage-update` entrypoint refreshes approvals through `pending-update`. Unlocking also triggers a refresh. The notification service reconciles the queue into transient cards in its existing bar-anchored deck, so cards are neither persisted nor added to history. A failed fetch preserves the previous view; an empty successful queue removes it. Each click refreshes the queue and compares the displayed digest before dispatching approval. No mutation is retried automatically.

The GTK4 launcher publishes its per-launch loopback port and token in `$XDG_RUNTIME_DIR/orb-locald.json`, atomically with mode 0600, only for the primary desktop instance holding its single-instance lock. Normal exit removes it. The Python bridge requires a same-user, regular, non-symlink 0600 file, disables HTTP proxies and redirects, and never prints the token.

## Required Orb interface

Orb uses `POST http://127.0.0.1:<port>/__orb_rpc`, header `X-Orb-Token`, request `{command,args}`, and response `{result}` or `{error}`. The implemented contract is documented in Orb's `docs/pending-requests-rpc.md`:

- `pending_requests_list`, args `{}`: returns Core's unified queue unchanged (`{items:[...],mode:...}`). Canonical item fields come from `orb/src/approvalQueue.ts` and `lean/OrbCore/OrbCore/SecretAndApproval.lean`: `kind` (`secret`, `privilege`, `mission_access`), `id`, `tier`, `target`, `risk`, `reason`, `digest`, `request`, and requester metadata. No per-kind fallback is used.
- `pending_requests_approve`, args `{kind,id,expected_digest}`: the client supplies the digest from the displayed card, never a replacement digest from a refresh. Locald refreshes the queue and rejects a mismatch before signing exactly one item. A single-item action explicitly confirms that item's critical risk. Cards show kind, tier, target, requester, risk, reason, and available scope metadata (projects, destination, host, mission, unit, lifetime, session scope), without secret values. Critical actions say “Confirm critical · fingerprint”; scope text is not collapsed to the normal two-line preview.

Locald fails closed on locked, missing, failing, or unrecognized `omarchy-shell lock isLocked` output for both commands and rechecks after signing. It pins the connection generation, resolves an existing enrolled device, validates a server challenge bound to the exact approval body, signs with grace zero, and submits once. There is no enrollment, unsigned fallback, or mutation retry. Errors stay errors and successful results are returned unchanged. Tethers are outside this contract.

Core's queue route is `GET /api/approvals/queue`; its signed approval route is `POST /api/approvals/approve-all` with `{items:[{kind,id,digest}],confirm_critical}`. The status bar never invokes that route directly. The locald implementation must handle explicit single-item critical confirmation and preserve Core's authorization checks.

## Verification

Locald currently refuses secret tiers other than `read`, and privilege requests whose present `allowed_units` field is not an array or contains more than one entry, because of existing Core bugs. These requests remain visible with their complete `allowed_units` value and an **Open Orb** action, but no approval action. Direct client approval dispatch also refuses them. Opening Orb only opens/focuses the application; it does not bypass locald's guard or submit an approval.

Run `python3 -B pkgs/test-orb-pending.py` and `python3 -B pkgs/orb-agent-sync.py --self-test`. The Nix package check runs both. Omarchy's `test/shell.d/notifications-test.sh` includes reconciliation, transient-history exclusion, locked-action refusal, and lock-during-deferred-insertion coverage.

Live verification requires both updated repositories and an Orb build implementing the RPCs: check arrival, duplicate refresh, expiry/removal, fingerprint cancellation/success, lock during an open card, lock during fingerprint authentication, and unlock refresh. No new polling loop is added; refresh cadence follows the existing usage sync.
