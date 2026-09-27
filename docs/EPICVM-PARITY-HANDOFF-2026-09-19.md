# EpicVM dashboard parity audit and implementation handoff

Audit date: 2026-09-19. This document is the handoff prompt. Give the entire document to the implementation agent.

## Task

Bring EpicVM's dashboard and portal into consistent operation across local Docker VMs, remote Hyper-V VMs, supported provisioning profiles, portal accounts, dashboard administrators, and user-owned Cloud PCs. Fix the confirmed gaps below, investigate the explicitly qualified findings, test the meaningful boundaries, build locally, deploy scoped changes, and verify the result in the actual product.

The initiating user reported missing machines and users in Users & Access. Do not interpret parity as giving every identity the same permissions or forcing every provider to support identical operations. Show a complete, correctly scoped inventory, explain identity and capability differences, and route supported operations to the correct resource.

## Environment and boundaries

- Repository: `C:\Users\Epic\Documents\Blobe-Vm-Manager`, also available as `E:\Projects\Documents\Blobe-Vm-Manager`.
- Audited branch `production`, HEAD `eb8b28e`. The checkout is heavily dirty, with existing Astra, Omarchy, provisioning, and frontend work. Inspect before changing anything; preserve unrelated edits. No reset, clean, broad revert, blanket commit, or OpenCode.
- Runtime: `ssh kvm2`; container `blobedash`; state `/opt/blobe-vm`; dashboard `https://techexplore.us/Dashboard/`; portal `/EpicVM/portal`.
- Windows service: `EpicVMRemoteAgent`; provisioning store `E:\EpicVM\provisioning-jobs.json`.
- Build on the Windows PC, never on KVM2. Deploy Windows agent source changes using `scripts/Install-EpicVMAgentSourcesSafe.ps1` only if needed.
- Preserve automatic gaming readiness. Human keyboard/mouse attestations must remain optional/unused and may remain false. Preserve automated changing non-black video, transport, provisioning, capture, GPU-P, and route checks.
- Retained ready VM: `gaming-e2e-0919`, ID `d9be8f7c-a8fd-403c-acc2-ae56c9cfcc78`, host `epic-pc`, job `eb5b1e9204fa45e0b9598e584c98616d`. Do not delete, reset, or reprovision it for parity work.
- Two pending records were cleared earlier at the user's request. Do not restore them as part of a migration. The recovery backup is `E:\EpicVM\provisioning-jobs.before-queue-clear-20260919-141105.json`.
- Avoid asking routine implementation questions. Escalate only unavoidable human actions or material unresolved destructive/data-ownership decisions. Do not merge case-colliding accounts, delete user machines, reset production passwords, or bulk-reassign ownership as a shortcut.

## Evidence and limitations

This was a source and live-runtime audit, not a complete interactive browser regression. No production mutation endpoints were invoked. Existing state was read, provider inventory was queried, and the deployed Users handler was evaluated in a request context with database initialization disabled to avoid migrations. This handler evaluation was not an authenticated public HTTP test. Admin credentials are hashed; no new login session was created for the audit.

Live observations:

- Local inventory has 3 machines: `Jason`, `testprovvm`, `uiaprv1787189877`.
- `epic-pc` has 8 inventory records: `EpicVM-CleanTemplateSource`, `epicvm-local-gaming-1`, `EpicVM-Omarchy-TemplateBuilder`, `gaming-e2e-0919`, `indo`, `prod-gaming-verify-1`, `testre`, and `Windows 11 dev environment`.
- The deployed Users handler returns 3 selectable VMs, despite those 11 host inventory records.
- Five enabled Cloud PC records exist, all owned by `epic`. They are a separate resource type and must not be counted as five additional managed VMs without labeling them. They are not in the host fleet inventory.
- The portal SQLite database has 9 users, and the deployed Users handler returns all 9: `bptest`, `Deon`, `Epic`, `epic`, `indo`, `mari`, `nyxieadmin`, `nyxietest`, `sara`.
- Existing assignments include `bptest -> prod-gaming-verify-1`, `indo -> indo`, and `epic -> uiaprv1787189877`. Two assignments therefore point at remote VMs absent from the Users selector.
- Configured dashboard admins are `Epic` and `nyxieadmin`; this is a separate credential realm from identically named portal records. No passwords or hashes belong in the output or handoff.
- `Epic` and `epic` coexist as distinct portal records. This is a real identity ambiguity, not proof of unintended duplicate accounts.
- Live `_vm_access_mode` returns `public` for `indo`, `gaming-e2e-0919`, and an existing Cloud PC ID. Provider access behavior must be tested carefully against its specialized checks before concluding a particular console is exposed.
- Local and deployed `app.py` and `remote_agent_client.py` hashes match. `cloud_pc.py` also matches after CRLF/LF normalization; its initial raw hash difference is not a deployment defect.
- An in-memory signature check of deployed `_update_user` rejects `account_status` with `TypeError: got an unexpected keyword argument 'account_status'`. No approval was performed.
- A direct Node check of `normalizeVmStatus` reproduces both state defects in item 10 below.

Do not claim the reported missing-user symptom has been fully reproduced. No missing portal DB row was found. Investigate browser errors, stale UI, identity realm expectations, and any additional intended account sources; do not invent a second signup database. Signup currently writes to the same portal SQLite users table.

Source line numbers below refer to the audited checkout and may shift. Search by function name before editing.

## Findings and expected fixes

### 1. P1: Users & Access lists only one provider

Confirmed live and in source. `dashboard/app.py:4601` (`dashboard_users_list`) returns `vms: manager_json_list()`. Normal requests default to local. `_known_vm_names` at line 2713 already validates across providers, while `dashboard_v2/src/pages/Users.jsx` builds its options from the local-only response.

Use the appropriate complete inventory for admin assignment, with host, resource type, stable identity, and capability metadata. Preserve assigned but unavailable resources in the editor. Saving unrelated changes must never remove assignments merely because a provider was offline or absent from the current options.

### 2. P1: Resource identity and ACLs are still keyed only by VM name

Confirmed structural defect. SQLite `user_vm_access` and `access_requests` use `vm_name` without host/provider identity (`app.py:2630`). `_known_vm_names` collapses names into a set. `portal_vms_api` at line 4169 collapses fleet entries into a dictionary keyed by name. Users select values and several frontend maps are name-only.

Introduce a stable, provider-qualified resource identity throughout inventory, assignments, requests, links, status, actions, caches, and UI keys. Migrate existing grants safely and idempotently. Ambiguous old names must be reported for resolution, never expanded to every matching host. Verify same-name machines on two hosts remain independently visible and authorized.

### 3. P1: Remote access settings are fabricated/defaulted rather than centrally managed

Confirmed in source with live metadata evidence. Remote `api_get_vm_settings` (`app.py:4949`) hard-codes `accessMode: public`, `assignedUsers: []`, and empty presentation fields. The remote setter rejects changes with `remote_settings_read_only`, while the Manage UI exposes only remote lifecycle controls. `_vm_access_mode` at line 2949 reads local instance metadata and defaults to public; `_user_can_access_vm` and `_enforce_vm_user_access` have no provider argument.

Store dashboard-owned ACL/presentation metadata independently of local Docker directories and resolve it by resource identity. Read actual grants and policy for remote VMs. Make public/restricted behavior explicit and consistent at API, wrapper, and streaming proxy boundaries. Test anonymous, owner/assigned user, unrelated user, disabled/rejected account, and admin behavior with fixtures. Do not silently make existing restricted resources public during migration.

### 4. P1: Approving a VM access request raises an argument error

Confirmed deterministic defect. `dashboard_access_request_action` (`app.py:4655`) calls `_update_user(..., account_status='approved')`, but `_update_user` (`app.py:2866`) does not accept that keyword. Repair the contract and make the grant/request-state change atomic. Clarify whether approving a VM grant is also intended to approve an account; do not conflate them accidentally. Test repeat approval and missing/deleted users/resources.

### 5. P1: Identity realms and administrator roles are not represented accurately

Confirmed model/UI discrepancy; missing-user allegation remains unproven. `_admin_credentials`/`_extra_admin_credentials` authenticate dashboard admins from configuration. Portal users and `is_admin` live in SQLite. `Users.jsx` neither identifies realm nor displays `isAdmin`; its create form has no role field even though the API accepts `isAdmin`. Dashboard authentication does not simply consume the portal admin flag.

Provide a clear account/role/source model and an accurate admin view. Config-backed admins may be visible as protected/read-only identities instead of pretending the portal password-reset endpoint controls them. Establish username case policy prospectively and inventory existing collisions without merging them. Verify the reported missing-user browser experience against API responses and the authoritative sources before claiming it fixed.

### 6. P1: Account approval's provisioning state is disconnected from real jobs

Confirmed in source. `_provision_user_linux_vm` (`app.py:4675`) always selects local creation, maps usernames to lowercased VM names, returns `creating` even when create reports failure, and is called synchronously by account approval. It does not create a tracked provisioning job here. Search shows no durable success reconciliation for the account's stored `provisioning_state`. An existing same-name VM is treated as acceptable and can be assigned, which needs explicit ownership validation.

Separate approval from a durable provisioning workflow with idempotency, provider/profile selection or documented defaults, ownership checks, errors, retry, and eventual ready/failed state. Test `Epic` versus `epic` name collisions and pre-existing VMs. Do not commandeer an existing VM based solely on its name.

### 7. P1: Existing portal sessions do not enforce current approval status

Confirmed source mismatch; no unauthorized production action attempted. Login rejects non-approved users (`app.py:4096`), but `_verify_portal_token` checks existence and disabled state without rejecting pending/rejected accounts. `portal_auth_required` consequently does not apply the login approval rule on every request. `_init_users_db` also repeatedly promotes pending users with grants to approved, beyond a one-time schema migration.

Define and enforce one account-state policy across existing sessions, login, status, portal APIs, and console access. Make migration logic truly migration-scoped. Test rejection/disable/delete after session issuance. Review password-reset and role-change session invalidation as part of the policy, without claiming these were exercised live.

### 8. P1: Cloud PCs are absent from admin inventory and account lifecycle management

Confirmed live: five enabled records are returned by `_load_cloud_pcs`, appended separately only to the owner's portal in `portal_vms_api` (`app.py:4253`). `manager_json_fleet_list` contains only host providers. Users & Access does not show Cloud PC ownership, and `_delete_user` removes SQL grants/users but has no Cloud PC ownership handling.

Expose Cloud PCs as a distinct admin resource type with owner, connection/pairing state, supported controls, and clear lifecycle semantics. Decide how deletion/disable/rename affects ownership without deleting physical PCs or silently transferring them. Keep external PC streaming controls distinct from VM power controls. Include disabled registry records in an admin view or make the filter explicit.

### 9. P1: Generic Cloud PC start/stop dispatch is ordered incorrectly

Confirmed code path with live metadata evidence. `portal_start_vm`/`portal_stop_vm` (`app.py:4292`, 4316) enter Cloud PC dispatch only if `_user_can_access_vm` is false. The generic ACL helper returns true for a resource whose local metadata defaults to public, as observed for a real Cloud PC. The request then goes to a VM host manager instead of `_cp_start`/`_cp_stop`. Specialized owner-scoped Cloud PC endpoints already exist.

Resolve resource kind before dispatch and enforce owner/admin access independently of the generic VM public-default logic. Test the owner, a different portal user, and admin against both generic and specialized routes. Use mocks/fixtures to verify dispatch; do not stop production PCs as a test. The portal currently calls generic start/stop/restart.

### 10. P1: Offline and local status normalization contradicts actual state

Reproduced with direct function calls. `manager_json_list` (`app.py:3334`) changes cached remote `status` to `offline` and sets `host_online=False` but preserves `state`. `dashboard_v2/src/lib/vmStatus.js:28` prioritizes `state` and overwrites `running`, turning `{state:'Running', status:'offline', host_online:false}` into `status:'Running', running:true`.

The same normalizer turns `{status:'blobevm_demo (running)', running:true}` into `running:false` because it only recognizes an exact state alias. Local inventory currently returns strings such as `blobevm_Jason (stopped)`.

Represent host reachability, stale last-known power state, provisioning readiness, and health separately. Normalize at a shared contract boundary. Test running/stopped local formats, transitions, unknown provider state, and stale cached remote state. UI must not present stale running state as reachable/ready.

### 11. P1: Portal readiness is inferred from power rather than provisioning evidence

Confirmed source mismatch. `portal_vms_api` classifies running VMs as ready with a short transition list that omits agent stages such as `streaming_setup`. `epicvm_web/src/pages/Pending.jsx` also accepts `v.running` as ready. Remote standard Windows VMs lacking explicit OS metadata fall through to Linux classification, and gaming OS fallback can also show Linux.

Return separate power, provisioning, console, and reachability state using provider facts. Use actual guest OS/profile metadata. Honor the automated gaming gates already implemented; never revive human keyboard/mouse gates. Test running-but-unready, failed capture/route, offline host, gaming Windows, standard Windows, Linux, and experimental Omarchy records.

### 12. P2: Telemetry and activity cover local Docker while inventory is fleet-wide

Confirmed source mismatch. `/stats` uses local psutil/proc data (`app.py:7261`). `/vm/stats` uses Docker-only statistics (`app.py:7492`), including arbitrary container names rather than filtering exclusively to VM containers. `VMManager.jsx:414` joins stats/optimizer/profile maps by name. Home combines fleet machine counts with one host's metrics; resource usage has no host selector. Global notifications (`app.py:8053`) enumerate local inventory and optimizer events only.

Label host scope, return provider-qualified metrics with units and availability, and filter service containers from VM statistics. Wire remote metrics already available in remote settings/inventory when meaningful. Unsupported metrics must remain unavailable, never synthetic zero/healthy. Keep optimizer local unless a provider explicitly supports it; expose that limitation. Include relevant remote provisioning/console events in activity without conflating them with Docker optimizer events.

### 13. P2: Logs, execution, recovery, and API documentation lag provider support

Confirmed source gaps. `Logs.jsx:17` and `AdvancedTools.jsx:14` call local `/list`. Logs omits host when requesting VM logs even though the backend log route already supports remote hosts. Exec (`app.py:7557`) unconditionally performs Docker exec. `_recover_vm` (`app.py:3572`) gets before/after health from local Docker while actions use `_vm_host()`, so remote selection and verification can disagree. APIInfo hard-codes older endpoints and omits host/provisioning/Cloud PC contracts.

Make selection and action context provider-qualified. Gate unsupported exec/recovery/optimizer/app-install/rebuild operations with explicit capabilities. Audit the remaining local command endpoints for accidental remote fallback before exposing them in fleet UI. Use provider status for recovery verification. Update in-product API guidance and tests.

### 14. P2: Inventory exposes unmanaged/template machines without a sufficient distinction

Live inventory includes two template/build VMs and a Windows VM with spaces. Hyper-V listing (`remote_agent/windows/providers/HyperVProvider.ps1`, `Get-EpicVMHyperVVMs` around line 770) enumerates all `Get-VM` records. Public EpicVM routes/agent operations use narrower name contracts in several places.

Keep visibility where intended, but classify managed, external, template, and protected resources and expose accurate per-resource action capabilities. Use stable provider IDs for resources whose display names fail legacy route rules. Do not simply hide all unusual names or make protected machines deletable to achieve parity. Verify action rejection against fixture/template records without destructive live tests.

### 15. P2: Failed inventory fetches can look like a legitimate empty list

Confirmed source behavior. Fleet enumeration omits unavailable providers when no cache exists. Users.load parses bodies and assigns empty arrays without checking HTTP status/`ok`. Home's fleet failure falls back to an empty or old list without a dedicated inventory-error state. Pending provisioning listing swallows provider unavailability and may return an empty list.

Return provider availability, partial-result/freshness information, and request errors separately from resource arrays. Preserve last-known records and selections. A disconnected host must not imply its VMs, assignments, or jobs were deleted. Show actionable errors without blocking healthy providers.

### 16. P2: Portal account status and lifecycle UI are incomplete

Confirmed source behavior. Signup produces no portal session; non-approved login is refused, while the SPA expects authenticated pending/rejected users for its status gate. `Pending.jsx` polls VMs only when already approved; `App.jsx` refreshes account identity on navigation, not continuously while waiting. `Portal.jsx` loads once/action completion without periodic state refresh. `restartVm` waits up to 30 seconds but starts anyway after timeout and does not recognize Hyper-V `off` as stopped.

Provide an authenticated status-only path or another explicitly scoped account-status flow that does not grant VM access. Refresh approval/provisioning state appropriately. Make restart semantics provider-specific and fail or remain pending on a stop timeout. Cloud PC restart must mean what its streaming provider supports, not a fictitious physical power cycle.

### 17. P2: User review and request history omit information needed to manage new accounts

Confirmed source behavior. Users API returns `email`, `who`, `isAdmin`, and `vmName`; Users.jsx does not show those fields for account review. Requests are silently limited to the latest 200 with no pagination/count contract. `_delete_user` leaves access requests behind, and role/ownership provenance is absent from the view.

Show relevant signup/review details and role/source labels, with safe pagination/filtering and deterministic account lifecycle handling. Do not reinterpret guest Windows/Linux accounts, Moonlight service accounts, and portal users as a single editable account type. Identify which account types the admin product is meant to manage.

## Implementation order

1. Refresh live evidence and inspect dirty work. Capture a safe data backup and explicit inventory/identity map. Validate findings against the current checkout before changing code.
2. Fix the broken access approval contract and define stable resource identity, ACL storage, and migration rules. Address the Cloud PC dispatch and existing-session approval inconsistency with fixture-based tests.
3. Apply the shared inventory and identity contracts to Users, VM Manager, Home, portal, assignments, requests, links, and metadata. Resolve the missing-user complaint with concrete source/API/browser evidence.
4. Correct status/readiness and durable approval provisioning. Connect metrics/logs/events and capability-aware tools; make unavailable/unsupported states truthful.
5. Build affected frontends locally. Deploy scoped artifacts/backend changes. Verify actual browser flows and provider responses, preserving existing gaming readiness behavior.

## Acceptance criteria

- Inventory reconciliation: every intended managed VM and Cloud PC is accounted for across admin views; template/external exclusions or capability restrictions are explicit. Baseline is 3 local + 8 remote inventory records + 5 separately typed Cloud PCs, subject to live changes.
- Users: all authoritative portal accounts appear; configured admins and portal admin flags are accurately identified. The audit baseline is 9 DB users, not proof of a tenth missing account. Resolve case collisions without automatic merges.
- Assignments: remote grants appear and survive unrelated saves and provider outages. Two same-name VMs on different hosts have distinct keys, links, grants, and actions. Legacy migration is backed up, idempotent, and fails visibly on ambiguity.
- Authorization: fixture tests cover anonymous, assigned/unassigned user, owner/non-owner, admin, disabled/rejected user, and session state changes for API, wrapper, and streaming paths.
- Approval: access requests complete without the TypeError; account approval creates or links only an authorized resource and tracks real progress/failure/retry. Repeat requests are idempotent.
- Cloud PCs: visible to authorized administrators with ownership, correct stream lifecycle dispatch, and no fake VM power semantics. Deleting an account cannot silently strand or reassign its records.
- State: running is not sufficient for ready. Disconnected hosts remain disconnected in every view; stale data is labeled. Local and remote status formats are covered. Required automated gaming evidence remains intact; keyboard/mouse flags need not be true.
- Tools: logs/status/actions carry the selected provider identity. Unsupported exec, recovery, optimizer, template, and destructive actions are disabled with a reason and rejected server-side.
- Errors: unavailable hosts and failed requests do not look like successful empty inventories. Existing grants and history remain visible.
- UI: verify Users & Access, VM Manager, Home, Logs, Resource Usage, Advanced Tools, account signup/approval status, and owner portal through the live supported routes. Preserve the already repaired `/Dashboard` and `/EpicVM/Dashboard` router bases.

Use focused existing suites, including relevant cases in `tests/test_admin_vm_sso.py`, `test_remote_host_registry.py`, `test_cloud_pc_api.py`, `test_cloud_pc.py`, `test_provisioning_api.py`, `test_epicvm_overview.py`, `test_epicvm_notifications.py`, `test_epicvm_metadata.py`, and frontend tests. Add behavioral tests for the real failures and migration boundaries, not source-string assertions that only mirror implementation. Run agent tests only for affected contracts. Use isolated fixtures for destructive and ownership tests; do not reset live users/VMs to obtain coverage.

Final delivery must distinguish implemented fixes, live verification, intentional provider limitations, and unresolved items. Include a count reconciliation and a per-finding disposition. Passing builds alone are insufficient; do not claim every possible EpicVM inconsistency has been eliminated without stating audit coverage.
