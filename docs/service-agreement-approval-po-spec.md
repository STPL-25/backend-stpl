# Fixed-Recurring Service: Agreement Approval → Auto-Fill PR → Workflow/Direct PO

Status: draft spec for review · Author: generated with Claude Code · Date: 2026-08-14

## 1. Requirement (as given)

> In Service, if a service is Fixed Recurring, it needs an approval flow with period
> selection. E.g. Rent, from 1 Jan to 31 Dec, ₹100,000/month, recurring. It goes to an
> approval flow with an uploaded agreement/document. If approved, it's valid till 31 Dec.
> When a user then selects company, division, branch, department and service = Rent, the
> values (rate, period) should auto-populate, and recur like that. In the approved PR, if
> a workflow is configured for PO generation, follow it; otherwise, after PR generation,
> generate the PO directly and send it.

This is new functionality — see §7 for what already exists vs. what must be built.

## 2. What already exists (verified in code)

| Area | File(s) | Notes |
|---|---|---|
| Service billing-type catalogue | [05_service_masters.sql](../sql/05_service_masters.sql) | `service_type_master` seeded with `FIXED_RECURRING`, `VARIABLE_RECURRING`, `VENDOR_BILL` |
| Service catalogue | same file | `service_master.is_recurring`, `.recurrence_cadence` (`DAILY\|EVERY_N_DAYS\|MONTHLY\|QUARTERLY\|HALF_YEARLY\|YEARLY_FIXED_DATE`), `.recurrence_interval_days` — **rate and period are not modeled here**, only the recurrence pattern |
| Generic approval engine | `src/WorkFlowApproval/*`, tables `approval_workflow_master`, `workflow_types`, `workflow_stage` | Keyed on `(com_sno, div_sno, brn_sno, dept_sno, entity_type)`; `entity_type` sourced from new `entity_master` ([04_entity_master.sql](../sql/04_entity_master.sql)), currently seeded with `Masters, PurchaseRequisition, PurchaseOrder, GRN, Payment, KYC` |
| PR creation + its own approval | `src/PR/*`, SP `usp_InsertPurchaseRequest` ([06_usp_InsertPurchaseRequest_v2.sql](../sql/06_usp_InsertPurchaseRequest_v2.sql)), `sp_approve_pr_datas` | Resolves workflow for `entity_type='PurchaseRequisition'`; **throws error 50006 if none configured** — no bypass today. `pr_item_details` already has a nullable `service_sno` column for service lines. |
| Service PO | `src/ServicePO/*`, SPs in [07_po_service_extensions.sql](../sql/07_po_service_extensions.sql) | Resolves workflow for `entity_type='ServicePO'`; **throws error 52006 if none configured** — same gap. |
| Direct/no-workflow PO precedent | `sp_nt_CreateCallOffPO` ([09_call_off_po.sql](../sql/09_call_off_po.sql)) | Call-off against an already-approved STANDING blanket PO sets `workflow_types_id = NULL, status = 'A'` immediately — the pattern to copy for the "no workflow → direct" branch. |
| File upload | `src/Utils/ImagesUpload/ImgUpload.js` | Used today for quotation files (`QUOTATION_DATAS`) and PR item attachments (`PR_ITEMS`) via `ftpUploader`. Reusable for agreement documents. |
| Recurring scheduling | — | **Nothing exists.** No cron/scheduled job anywhere in `backend-stpl`, `grn-service`, or `notification-service`. |
| Service agreement (rate + period + document, tied to org scope) | — | **Does not exist.** This is the central new entity this spec introduces. |

## 3. New entity: Service Agreement

A Service Agreement is the record that answers "what does Rent cost, for how long, for
this company/division/branch/department, and what's the proof (contract)?" It sits
*above* `service_master` — `service_master` says "Rent is a Fixed Recurring, monthly
service"; the Agreement says "for HO/Finance/Chennai Branch/Admin dept, Rent is
₹100,000/month from 2026-01-01 to 2026-12-31, per this uploaded PDF."

### 3.1 Table: `dbo.service_agreement`

```sql
CREATE TABLE dbo.service_agreement (
    agreement_sno         INT IDENTITY(1,1) PRIMARY KEY,
    agreement_no           VARCHAR(30)    NOT NULL,        -- system-generated, e.g. AGR-2026-000123
    com_sno                INT            NOT NULL,
    div_sno                INT            NOT NULL,
    brn_sno                INT            NOT NULL,
    dept_sno               INT            NOT NULL,
    service_sno            INT            NOT NULL,        -- FK service_master; must be is_recurring=1
    vendor_sno              INT           NULL,             -- landlord/vendor, if applicable
    rate_amount             DECIMAL(18,2) NOT NULL,         -- e.g. 100000.00
    rate_uom_sno             INT          NULL,             -- FK uom_master, defaults from service_master
    recurrence_cadence       VARCHAR(20)  NOT NULL,         -- copied from service_master at creation, can differ per agreement
    period_start_date        DATE         NOT NULL,         -- 2026-01-01
    period_end_date          DATE         NOT NULL,         -- 2026-12-31
    agreement_doc_url         NVARCHAR(500) NULL,           -- uploaded contract/agreement file
    remarks                   NVARCHAR(500) NULL,
    workflow_types_id          INT        NULL,             -- resolved at submit time, entity_type='ServiceAgreement'
    current_approver_id        VARCHAR(20) NULL,
    status                     CHAR(1)    NOT NULL DEFAULT 'D',  -- D=Draft, P=Pending approval, A=Approved, R=Rejected, X=Expired
    is_active                  CHAR(1)    NOT NULL DEFAULT 'Y',
    created_by                 VARCHAR(20) NULL,
    created_at                 DATETIME   NOT NULL DEFAULT GETDATE(),
    modified_by                VARCHAR(20) NULL,
    modified_at                DATETIME   NULL,
    CONSTRAINT UQ_service_agreement_no UNIQUE (agreement_no),
    CONSTRAINT FK_service_agreement_service FOREIGN KEY (service_sno) REFERENCES dbo.service_master (service_sno),
    CONSTRAINT CK_service_agreement_period CHECK (period_end_date > period_start_date)
);

CREATE INDEX IX_service_agreement_scope
    ON dbo.service_agreement (com_sno, div_sno, brn_sno, dept_sno, service_sno, status);
```

`entity_master` gets one new seed row: `ServiceAgreement`. No change to
`approval_workflow_master`/`workflow_types`/`workflow_stage` — an admin just configures a
workflow for `entity_type='ServiceAgreement'` at whatever org scope needs it, the same way
`PurchaseRequisition` or `KYC` workflows are configured today.

### 3.2 Lifecycle

```
Draft (D) --submit--> Pending (P) --stage-by-stage approval--> Approved (A)
                                   \--any stage rejects-------> Rejected (R)
Approved (A) --period_end_date passes (daily job)------------> Expired (X)
```

`D` is reserved in the schema but not written by `sp_nt_CreateServiceAgreement` —
consistent with how PR drafts already work (`PR.repository.js#saveDraft` caches drafts in
Redis, not as a `pr_basic_info` row), a Service Agreement draft is expected to live
client-side until submit, at which point it's inserted directly at `Pending`.

- **Submit**: resolves `workflow_types_id` for `(com_sno, div_sno, brn_sno, dept_sno, entity_type='ServiceAgreement')` exactly like `usp_InsertPurchaseRequest` does for PRs. If none configured, throw (an Agreement should always be reviewed by someone — this is not a candidate for the direct-bypass path in §6).
- **Approve**: reuse the same stage-progression shape as `sp_approve_pr_datas` (`approval_stages` JSON, `required_approvals`, `can_forward`/`can_backward`) — new SP `sp_approve_service_agreement`, modeled 1:1 on it rather than generalizing `sp_approve_pr_datas` itself (keeps the two entity types decoupled, matching how `ServicePO` already has its own `sp_nt_ApproveServicePO` sibling to `sp_approve_pr_datas`).
- **Reject**: `status='R'`, requester notified (notification-service email).
- **Expire**: a daily job flips `status='A' AND period_end_date < today` to `status='X'`. Expired agreements stop being offered for PR auto-fill (§4) and stop spawning recurring PRs (§5).

### 3.3 Document upload

New endpoint, e.g. `POST /api/service-agreement` (multipart), following
`PurchaseTeam.controller.js#createSupplierQuotation`'s pattern: file goes through
`ftpUploader` into a new FTP folder `NON_TRADE_DATAS/SERVICE_AGREEMENTS`, URL stored in
`agreement_doc_url`. Required before submit — no submitting an agreement without a
document.

## 4. PR line auto-fill from an approved Agreement

When a requester builds a PR line and selects Company → Division → Branch → Department →
Service, and the selected service's `service_type = FIXED_RECURRING`:

1. Backend looks up `service_agreement` for that exact `(com_sno, div_sno, brn_sno,
   dept_sno, service_sno)` with `status='A'` and `today BETWEEN period_start_date AND
   period_end_date`.
2. **If found**: the PR line's rate, UOM, and cadence auto-populate from the agreement and
   render read-only (a requester shouldn't be able to type a different rent figure than
   what was actually approved). The line also carries `agreement_sno` and
   `period_end_date` for reference/audit and for §5.
3. **If not found**: block that PR line with a clear message ("No approved agreement for
   Rent in this Branch/Department — create and get an agreement approved first") rather
   than silently allowing free-text entry. This keeps the control meaningful: the whole
   point of the agreement gate is that nobody free-types a rent figure.

### 4.1 Data model change — ✅ done, [sql/12_pr_agreement_autofill.sql](../sql/12_pr_agreement_autofill.sql)

```sql
ALTER TABLE dbo.pr_item_details ADD agreement_sno INT NULL
    CONSTRAINT FK_pr_item_details_agreement FOREIGN KEY REFERENCES dbo.service_agreement (agreement_sno);
```

`usp_InsertPurchaseRequest` gained the branch this section originally called for — landed
as a v3 replacement of the procedure (`CREATE OR ALTER`, following that specific
procedure's own existing convention rather than the `DROP`+`CREATE` style used elsewhere
in this repo):

- A pre-check (new error 50012) runs before any row is inserted: for every item whose
  service is `FIXED_RECURRING`, its `agreement_sno` must resolve to a `service_agreement`
  row that is `Approved`, currently in-period, and scoped to this exact PR's
  company/division/branch/department + that service. One bad line aborts the whole PR,
  same as the existing item-shape validation right above it — not a silently dropped row.
- The item `INSERT` gains a `LEFT JOIN` to `service_agreement` (same match conditions as
  the pre-check, so it's guaranteed to hit for every `FIXED_RECURRING` line and stay
  `NULL` for everything else). Where it hits: `unit`, `est_cost`, and `total_cost` are
  sourced from the agreement's `rate_uom_sno`/`rate_amount` instead of the client JSON,
  `qty` defaults to `1` (one billing period) instead of `0`, and the new `agreement_sno`
  column is populated. Product lines and non-`FIXED_RECURRING` service lines are
  untouched.
- No Node.js changes were needed — `PR.repository.js#createPrRecords` already
  `JSON.stringify()`s whatever `basicInfo`/`items` the client sends and passes it straight
  through with no field allowlisting, so `agreement_sno` on an item flows through
  automatically. The still-open piece is the frontend: nothing calls
  `GET /api/service_agreement/getActiveServiceAgreement` yet to actually populate that
  field (see §7's Backend checklist).

## 5. Recurring PR generation — ✅ done

"Recurring" here means: once an Agreement is approved, a PR for that period's installment
should appear automatically on each `recurrence_cadence` boundary (e.g. the 1st of every
month for Rent) without the requester re-entering anything, up until
`period_end_date`. This was the one piece of the spec with no adjacent code anywhere in
this repo to model after (confirmed by grepping `recurring|subscription` across all three
backend services — nothing), so the design below is new rather than a mirror of an
existing pattern.

**SQL** — [sql/13_recurring_pr_job.sql](../sql/13_recurring_pr_job.sql):
- New table `service_agreement_recurring_pr_log`, one row per
  `(agreement_sno, billing_period_start)`, `UNIQUE`-constrained — this is the idempotency
  guarantee: even if the sweep interval overlaps a slow run, only one process can ever
  claim a given period.
- New procedure `sp_nt_GetAgreementsDueForRecurringPR` (no params) returns exactly the
  agreements needing a PR *right now*. "Is today a boundary" is computed per
  `recurrence_cadence` with the `DATEADD(unit, DATEDIFF(unit, start, today), start) =
  today` idiom — true exactly on each anniversary of `period_start_date`, letting SQL
  Server's own date arithmetic handle short-month clipping instead of hand-rolling it.
  Excludes agreements already claimed (log table) **and** agreements already billed this
  period by a *manually*-created PR — a real gap this closes: without checking
  `pr_item_details.agreement_sno` (added in §4.1) against the previous boundary date, a
  requester using §4's auto-fill for the agreement's first period would get
  double-booked once the job caught up to the same period.
- Known limitation, intentionally out of scope for this pass: a `FAILED` log row still
  occupies its period slot, so a failed attempt doesn't auto-retry until the *next*
  boundary rather than the next sweep — avoids retry-storm complexity, but means someone
  should periodically query this table for `status='FAILED'`.

**Node** — `src/ServiceAgreement/jobs/RecurringPrJob.js`, started once from `index.js`
inside the `server.listen` callback:
- An in-process interval timer (default hourly, `RECURRING_PR_SWEEP_INTERVAL_MS`) rather
  than a `node-cron` dependency — the actual boundary logic lives in SQL, so this file
  only needs to poll periodically and stays correct regardless of exact firing cadence.
- Each sweep: fetch due agreements, reserve each one's log slot (skip silently if another
  process already claimed it — detected via the unique-constraint violation, SQL Server
  error 2627/2601), then call **`PRService.createPrRecords()` — the exact same code path
  a manual PR submission uses** (per this section's original requirement), so a
  job-generated PR automatically gets §4.1's agreement-validation and server-side rate
  override, and is otherwise indistinguishable from a hand-submitted PR in the PR tables.
  The item payload only needs `service_sno` + `agreement_sno` — `qty`/`unit`/rate are all
  supplied server-side by the v3 procedure.
- Also runs `sp_nt_ExpireServiceAgreements` (built in §3 but never called until now) on
  the same interval.
- Priority: a recurring PR has no human picking one, so `getDefaultPrioritySno()` reuses
  the existing `sp_nt_GetPriorityRecords` (the same procedure the "PriorityMaster" admin
  screen already depends on via `CommonMasterRepo.js`) rather than a new lookup — **not
  independently verified to exist on the live server**, only inherited as an assumption
  from that already-relied-upon reference.
- **Known, deliberately unaddressed limitation**: `usp_InsertPurchaseRequest` currently
  hardcodes `@created_by = 'KTM1148'` regardless of what the JSON payload contains (a
  pre-existing quirk documented in `06_usp_InsertPurchaseRequest_v2.sql` itself, not
  something introduced here) — so a recurring PR is **not** actually attributable to a
  distinct "system" user today. The `purpose` field (`"Recurring: <service> — <agreement
  no>"`) is the only way to identify a job-generated PR until that's fixed.

Open from the original design-pass list: exact firing *time* (currently just "whenever
the hourly sweep next runs," not pinned to a specific hour) and timezone handling
(`GETDATE()`/`CAST(... AS DATE)` use the DB server's local time — fine if that's the same
timezone the business operates in, worth confirming if not).

## 6. PR approval → PO generation: workflow vs. direct — ✅ done

This is the "if workflow present, follow it; else generate PO directly and send" rule,
and it applies at the **PO** stage, not the PR stage (the PR already always requires its
own workflow — see §2). Landed in
[sql/11_service_po_direct_issue.sql](../sql/11_service_po_direct_issue.sql) (a fresh
migration file, not an in-place edit to `07_po_service_extensions.sql` — this repo's
convention, per `03_workflow_types_description.sql`, is to `DROP`+`CREATE` a replacement
procedure in a new numbered file rather than rewrite an already-applied one), plus the
Node.js wiring to actually send the notification:

- **Was**: `sp_nt_CreateServicePO` resolved workflow for `(com_sno, div_sno, brn_sno,
  dept_sno, entity_type='ServicePO')`; threw error 52006 if none was configured. No
  bypass.
- **Now**: if no active `workflow_types` row is configured for that scope, the procedure
  no longer throws — it creates the PO directly with `workflow_types_id = NULL,
  current_approver_id = NULL, status = 'A'`, the exact pattern `sp_nt_CreateCallOffPO`
  already uses for call-offs against a STANDING PO. Error 52006 is retired; 52007 (a
  workflow *is* configured but its first stage has no approver — a real
  misconfiguration) still throws, since that's not "no workflow."
- The procedure's result set gains `is_direct_issue`. `ServicePO.service.js#createServicePO`
  checks it and, when true, fires `sendDirectIssuePOEmail` — vendor contact +
  item lines pulled fresh from `kyc_basic_info`/`po_item_details` (not trusted from the
  request payload), through the same `sendPOGeneratedEmail` helper
  (`Utils/Notify/notifyClient.js`) the supplier-quotation flow already uses for its
  `'PO ... auto-generated on final quotation approval'` case — fire-and-forget, so an
  email failure can't fail a PO creation that already committed.
- If a workflow **is** configured for that scope, behavior is unchanged: PO sits at
  `status='P'`, routes through `workflow_stage`s, and only sends to the vendor once the
  final stage approves (no code changed there — `sp_nt_ApproveServicePO` doesn't need to
  know about direct-issue POs, since they're never `Pending` in the first place).

This makes "is a workflow configured for ServicePO at this company/division/branch/
department" the single switch an admin controls per org unit — no new
service/category-level flag needed, since the org-scoped `workflow_types` config already
is that switch; today's bug is simply that its *absence* is treated as an error instead
of a valid "go direct" state.

**Not yet run against the database** — same caveat as §3's SQL: no migration runner in
this repo, needs manual execution against `10.0.21.8`.

## 7. Summary of changes required

### Database — ✅ done, [sql/10_service_agreement.sql](../sql/10_service_agreement.sql)
- New table `service_agreement` (§3.1) + `service_agreement_history` (audit trail, not
  in the original §3.1 draft — added because `po_history_data`, the table
  `sp_nt_ApproveServicePO` uses for the same purpose, isn't checked into this repo to
  copy the shape from directly, so it gets its own paired table instead)
- New `entity_master` seed row: `ServiceAgreement`
- New SPs: `sp_nt_CreateServiceAgreement`, `sp_nt_GetServiceAgreements`,
  `sp_nt_GetActiveServiceAgreement` (the §4 auto-fill lookup),
  `sp_nt_GetServiceAgreementsForApproval`, `sp_approve_service_agreement`,
  `sp_nt_ExpireServiceAgreements` (daily job target)
- ✅ done, [sql/11_service_po_direct_issue.sql](../sql/11_service_po_direct_issue.sql):
  `sp_nt_CreateServicePO` replaced with the direct-issue branch (§6) — not `sp_nt_ApproveServicePO`,
  which turned out not to need any change (see §6)
- ✅ done, [sql/12_pr_agreement_autofill.sql](../sql/12_pr_agreement_autofill.sql):
  `pr_item_details.agreement_sno` + `usp_InsertPurchaseRequest` v3 agreement validation
  and server-side rate override (§4.1)
- ✅ done, [sql/13_recurring_pr_job.sql](../sql/13_recurring_pr_job.sql):
  `service_agreement_recurring_pr_log` table + `sp_nt_GetAgreementsDueForRecurringPR`
  (§5)
- **None of the four SQL files (10/11/12/13) have been run against the actual database
  yet** — this repo has no migration runner, every `sql/*.sql` file here is applied by
  hand against `10.0.21.8`. Needs someone with DB access to execute all four, in order,
  before any of this works.

### Backend (`backend-stpl/src`)
- ✅ done: `ServiceAgreement/{repository,services,routes,controllers}` module,
  mirroring `ServicePO`'s exact folder shape and thin repository→service→controller
  layering. Mounted at `/api/service_agreement` (`index.js`), behind `verifyJWT` like
  every other protected route group:
  - `POST /createServiceAgreement` — `multer.any()` + `ftpUploader` into
    `NON_TRADE_DATAS/SERVICE_AGREEMENTS` (same pattern as `PurchaseTeam`'s quotation-file
    upload); rejects with 400 if the document upload didn't produce a URL, before ever
    calling the SP
  - `POST /approveServiceAgreement` — approve/reject, broadcasts on the
    `service_agreement:approval` socket.io room (new `join-/leave-service_agreement-approval`
    handlers added to `index.js`, mirroring `service_po:approval`)
  - `GET /getServiceAgreements` — filtered list
  - `GET /getActiveServiceAgreement` — the §4 auto-fill lookup PR line item forms will
    call; requires all 5 scope query params, returns `data: null` (not an error) when
    nothing matches
  - `GET /getServiceAgreementsForApproval` — the logged-in approver's pending inbox
  - All 5 files pass `node --check`; **not exercised against a running server** — a
    node process was already bound to port 7001 outside this session (presumably the
    user's own dev instance), so no competing preview was started. If it's running under
    `nodemon` it should already have hot-reloaded these files.
- ✅ done: the "does an approved agreement exist for this scope+service" call site —
  called directly from `PurchaseRequisitionPage.tsx` (frontend), no `PR.controller.js`
  change needed since it's a standalone read, not part of PR creation itself
- ✅ done: `src/ServiceAgreement/jobs/RecurringPrJob.js` — recurring PR generation (§5)
  and agreement expiry (§3.2), both on an hourly in-process interval started from
  `index.js`'s `server.listen` callback. Passes `node --check`; not exercised against a
  running server for the same port-7001 reason as above, and `sp_nt_GetPriorityRecords`
  (reused for the job's default priority) is inherited from existing code, not
  independently confirmed to exist live.

### Frontend (`nt-frontend-stpl`) — ✅ done

Built as a close mirror of the `ServicePO` frontend module (plain `useState` + native
`<select>`/shadcn components, not the heavier `FieldType`/`CustomInputField` machinery PR
uses) — confirmed via `Explore` research as the intended template, since the backend
`ServiceAgreement` module was itself built mirroring `ServicePO`'s backend module.

- `src/Application/ServiceAgreement/ServiceAgreementPage.tsx` — create form. Cascading
  company/division/branch/department pickers (same `useMasterOptions` +
  `com_sno`/`div_sno`/`brn_sno`-filtered `useMemo` recipe as `PRData.tsx`'s
  `usePRBasicInfoFields`, reimplemented inline in this simpler component style rather than
  imported, to stay consistent with `ServicePO`'s plain-`useState` pattern), service +
  optional vendor pickers, rate/UOM/cadence/period fields, a document-upload `<input
  type="file">`, and a list of existing agreements below. Submits flat multipart
  `FormData` (matching the backend's contract exactly, not PR's JSON-blob-in-FormData
  pattern) via `usePost`.
- `src/Application/ServiceAgreement/ServiceAgreementApprovalScreen.tsx` — approval
  screen, copied near-verbatim from `ServicePOApprovalScreen.tsx` (two-column card
  list/detail, `Dialog` for comments, socket room join/leave on the new
  `service_agreement:approval` room/events added to `Services/Socket.tsx`) with
  `po_basic_sno` swapped for `agreement_sno` throughout.
- `src/Services/Api.tsx` / `src/Services/Socket.tsx` — new URL constants and socket event
  constants, added in the same block style as the existing `ServicePO` entries.
- `src/ComponentsDatas/ComponentDatas.tsx` — both screens registered as lazy components
  under `ServiceAgreementPage`/`ServiceAgreementApprovalScreen`. **Not wired into the
  sidebar menu** — per this app's architecture (no URL routing for internal screens; menu
  items come from a backend-seeded `screens` table read via
  `apiFetchSidebarData`/`usePermissions`), that requires a DB-side `screens` row with
  `screen_comp = 'ServiceAgreementPage'` (and one for the approval screen), which is a
  data-seeding step outside this session's SQL files — someone with access to that
  admin/permissions flow (`UserRoleApprovalScreen.tsx`) needs to add it.
- **PR line auto-fill** (`PurchaseRequisitionPage.tsx`): a `useFetch` call against
  `getActiveServiceAgreement`, reactive on `currentItem.service_sno` +
  `basicFormData.{com,div,brn,dept}_sno` (skipped entirely unless `item_type === 'service'`
  and all five are set — no manual trigger needed, `useFetch`'s own dependency array
  handles refetching). Deliberately does **not** try to determine client-side whether the
  selected service is `FIXED_RECURRING`: if the lookup finds a match, `agreement_sno` is
  attached to the line and an info banner shows the resolved rate/period; if not, it's
  just a normal service line. The server's own validation
  (`usp_InsertPurchaseRequest` v3) remains the actual authority on whether an agreement
  was required — this is best-effort UI, not the enforcement point, so there was no need
  to guess at `ServiceMaster` options' exact field shape.

**Verification**: `npx tsc -b --force` (project-wide type-check) and `npx vite build`
both pass clean — the new chunks (`ServiceAgreementPage-*.js`,
`ServiceAgreementApprovalScreen-*.js`) appear correctly in the build output. `eslint`
flags a few findings (`@typescript-eslint/no-explicit-any`, `react-hooks/set-state-in-effect`)
in the new files, but a control check against the untouched `ServicePOPage.tsx`/
`ServicePOApprovalScreen.tsx` showed the identical categories of findings already present
there — confirmed pre-existing/tolerated style across this codebase (this project's own
`npm run build` script doesn't invoke `eslint` at all), not a regression. One genuine
unused-import lint error in the new code was found and fixed. **Not smoke-tested in an
actual browser** — no dev server was started this session (see the port-7001 note
above).

## 8. Open questions

1. Who can create a Service Agreement — same role as PR requester, or a narrower
   "facilities/admin" role?
2. Should an Agreement support a rate *change* mid-period (e.g. rent escalation on
   renewal), or is a new Agreement always required per period? (Spec above assumes the
   latter — simplest, matches "valid till 31 Dec" then presumably a fresh agreement for
   the next year.)
3. Exact firing schedule for recurring PR generation — start-of-month, N days before due,
   etc. — and what happens on a missed run (server down that day)?
4. Does the "direct PO" path in §6 still need the PR-level approver to explicitly confirm
   sending to the vendor, or is `status='A'` + auto-send fully unattended?
