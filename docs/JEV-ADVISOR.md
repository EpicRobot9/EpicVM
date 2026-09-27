# EpicVM Jev advisor

EpicVM uses Jev only for bounded, read-only semantic judgments. Code remains authoritative for authentication, authorization, CSRF, ownership, host eligibility, capability checks, resource limits, provisioning state, readiness, power actions, file isolation, and every mutation.

## Advisory tasks

- `ticket_triage`: product-area routing, impact, and missing-information checks for feedback and bug reports.
- `vm_request`: profile suggestion and request completeness for an administrator.
- `log_triage`: category, severity, and operator-attention screening over a bounded log tail.
- `provisioning_diagnosis`: ranks the next diagnostic area without triggering recovery or declaring readiness.
- `host_ranking`: ranks only hosts already proven eligible by deterministic code.
- `game_screening`: suggests a known deterministic importer family before the last-priority Codex fallback.
- `notification_priority`: ranks and detects probable duplicates without changing deterministic alert thresholds.
- `response_verification`: checks whether an administrator reply addresses the ticket and avoids unsupported claims.
- `browser_verification`: judges whether observed UI evidence communicates and satisfies a stated journey goal; deterministic browser assertions remain required.

Management uses `POST /EpicVM/api/management/jev/analyze`. Dashboard v2 uses `POST /dashboard/api/jev/analyze`. Both require existing administrator authentication, same-origin JSON, and CSRF protection supplied by their current clients. The TypeSafe credential stays server-side in `TYPESAFE_API_KEY`.

Requests are capped at 48 KB of JSON state and use a bounded timeout. Jev unavailability returns `503` and never blocks the underlying EpicVM workflow. Choice and Score confidence values are displayed as advisory evidence, not authorization.
