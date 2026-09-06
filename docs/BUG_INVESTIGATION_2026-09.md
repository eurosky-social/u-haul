# Bug investigation, September 2026

Findings from GitHub issues #18, #26, #27 and a batch of support tickets, checked
against the production database and container logs on 2026-09-05. Production runs
`ghcr.io/eurosky-social/eu-haul:latest` built 2026-07-06, which matches `main`
(`5530fd4`, no newer commits). The fixes below are implemented on the
`fix/investigate-bug-reports` branch; see "Implementation status" at the end.

Counts below are as of 2026-09-05. Container logs only reach back to the last
container recreate (2026-08-27); everything older comes from the database.

## Summary

| # | Finding | Impact in production | Priority |
|---|---------|----------------------|----------|
| 1 | Sweeper starts migrations before email verification | 34 of 36 "orphaned account" failures in 90 days are self-inflicted; 135 unverified migrations currently parked at `pending_plc` | P0 |
| 2 | Cancelled or failed migrations get resurrected by still-running jobs | 32 migrations show `pending_plc` with `error_code=cancelled`; they block retries for those DIDs | P0 |
| 3 | Status page never reloads for the blobs→PLC transition; upload progress written under the wrong keys | Issue #18 exactly: token form never appears, bar stuck at 40% | P1 |
| 4 | Wizard submits whatever is in the hidden custom-host field | Issue #27: two "No account found" rejections for a valid deactivated account | P1 |
| 5 | Captcha demanded for flows that cannot show one | 9+ "return to Bluesky" migrations stuck at the verification form; 6 "move to Bluesky" migrations fail at account creation | P1 |
| 6 | No-input XRPC POST carries body framing; single failure kills the migration | Issue #26 (self-hosted PDS behind Cloudflare Tunnel) | P2 |
| 7 | "Email already taken" is retried and reported as generic | One ticket; confusing failure email | P2 |
| 8 | No way to re-enter the new-account password after a 401 on the target | One ticket; migration is dead at the PLC step | P2 |

## 1. Sweeper starts unverified migrations (self-inflicted "orphaned accounts")

A new migration is saved with status `pending_account` and an
`email_verification_token`; nothing runs until `Migration#verify_email!` calls
`schedule_first_job`. `StuckMigrationSweeperJob` (every 5 minutes,
`config/sidekiq.yml`) selects every migration whose status is in `ACTIVE_STATUSES`
(which includes `pending_account`) and whose `updated_at` is older than 10 minutes.
A migration whose owner simply has not opened the verification email yet matches
after 10 minutes, and the sweeper enqueues `CreateAccountJob`.

The whole pipeline then runs without email verification: account creation on the
target, repo and blob transfer, preference import, rotation-key email, and the PLC
token request against the old PDS. Sweeper log line, from production:

```
[Sweeper] Re-enqueuing job for stuck migration EURO-… (status=pending_account, idle since <creation time>)
```

When the user finally enters the verification code, `verify_email!` calls
`schedule_first_job`, which unconditionally moves the status back to
`pending_download`/`pending_account` and runs the pipeline again from the start.
`CreateAccountJob` calls `createAccount` a second time, the PDS answers
`AlreadyExists`, `GoatService#create_account_on_new_pds` raises
`AccountExistsError`, and the migration fails with "Orphaned account exists on
target PDS, contact the PDS provider". The "orphan" is the account the same
migration created 10 to 40 minutes earlier.

Evidence (90 days): 36 migrations failed with `error_code=account_exists`; in 34
of them `progress_data.account_created_at` is set and precedes
`email_verified_at`, and `account_creation_started_at` (the second run) is within
seconds of `email_verified_at`. Across all verified migrations that created an
account, 49 of 363 created it before verification. All time, 222 migrations were
advanced while unverified (26 in the last 30 days); 135 are sitting at
`pending_plc` right now without a verified email.

Consequences beyond the failures: the email-ownership check is bypassed for every
affected migration, PLC-token and rotation-key emails go out before the user
consented, and users then cannot log in to the "orphaned" target account because
the generated password is only emailed on completion and is purged after 48 hours.

Fix:

- `StuckMigrationSweeperJob#find_stuck_migrations`: exclude
  `email_verified_at IS NULL`. Every migration requires verification
  (`after_create_commit :send_email_verification`), so this is safe.
- `Migration#verify_email!`: only call `schedule_first_job` when the status is
  still `pending_account`; otherwise log and leave the pipeline alone.
- `CreateAccountJob`: when `progress_data['account_created_at']` is present for
  this migration and the target reports a deactivated repo for the DID, treat it
  as our own account and advance instead of raising `AccountExistsError`.
- Add a regression spec: unverified migration older than 10 minutes must not be
  touched by the sweeper.

Data repair (proposal, not executed): the 135 unverified `pending_plc` rows are
consistent with the pipeline having run; once the fixes ship they complete
normally when the user verifies. The failed `account_exists` rows whose
credentials have expired cannot be resumed; those users need the PDS operator to
delete or reset the deactivated account, then retry.

## 2. Cancel and failure do not stop running jobs

`Migration#advance_with_job!` does `update!(status: new_status)` with no check of
the current status, and every job holds an in-memory `progress_data` that it later
writes back with `save!`. `confirm_cancellation` marks the migration failed and
stores `cancelled_at` in `progress_data`, but the running job then advances the
status to the next step and overwrites `progress_data` from its stale copy.
Result: `status=pending_plc`, `error_code=cancelled`, `cancelled_at` gone.
Production has 32 such rows plus one `pending_plc`/`account_exists`. Because
`Migration.active` and `no_concurrent_active_migration` only exclude `completed`
and `failed`, these rows produce the "already has an active migration in
progress" error reported in issue #18.

Fix:

- Make `advance_with_job!` conditional: `Migration.where(id:, status:
  previous_status).update_all(status: new_status)`; if zero rows changed, raise a
  terminal `MigrationAborted` that jobs rescue without retrying.
- Blob jobs check `migration.reload.failed?` between batches and abort.
- Never write `progress_data` from a stale copy: reload and merge, or use
  `update_column`-style JSONB merges for the progress keys.
- Data repair (proposal): `UPDATE migrations SET status='failed' WHERE
  error_code='cancelled' AND status <> 'failed';`

## 3. Status page (issue #18)

`app/views/migrations/show.html.erb` polls the JSON endpoint every 10 seconds and
only reloads the page for a few transitions. `pending_blobs` and `pending_plc` are
treated as one layout group, so the transition between them updates the header
text ("Waiting for your input") but never renders the PLC token form. That is the
reporter's "header and body contradict each other" observation.

Separately, `UploadBlobsJob#update_upload_progress` writes `blobs_uploaded`,
`bytes_uploaded` and only after all threads finish, while
`Migration#blob_upload_percentage` and `calculate_blob_statistics` read
`blobs_completed` and `bytes_transferred` (the `ImportBlobsJob` keys). On the
default backup-bundle path the bar therefore sits at 40% and the counters show 0
for the whole transfer. Note that `estimated_time_remaining` has the same key
mismatch.

Fix:

- Reload on any status change that changes the layout (simplest: reload whenever
  `data.status !== currentStatus`).
- Write `blobs_completed` and `bytes_transferred` from `UploadBlobsJob`, and write
  them periodically (every N blobs) rather than at the end.
- Add a visible "last updated" timestamp and a manual refresh button; surface
  fetch errors instead of swallowing them.

## 4. Wizard target host (issue #27)

The reporter's diagnosis is wrong for production: `verify_account_exists_on_pds`
already checks `RepoDeactivated` before the generic 400 branch (since February),
and the deployed image has it. The web log shows what happened instead: the
`POST /migrations` was submitted with `new_pds_host` equal to the user's handle on
the first attempt and to their email address on the second, so the account check
ran against `https://<handle>/xrpc/...` and returned "No account found".

Mechanism: the custom-host text input (`migration_new_pds_host`) is the value
carrier for every target choice. The wizard writes the selected preset into it and
hides it. The submit handler sets tokens, contact email and captcha fields from
`wizardData` but never re-asserts the host. A password manager or browser autofill
filling the "existing account on target" password field most likely wrote the
saved username into that hidden text input (handle on one saved login, email on
the other).

Fix:

- In the submit handler, set `migration_new_pds_host` from
  `wizardData.pdsVerifiedHost || wizardData.pdsHost`.
- `autocomplete="off"` on the custom host field and the target password field.
- Server side: reject a `new_pds_host` that is not a hostname (contains `@`,
  spaces, or equals the handle/email) with a specific error.
- Adopt the reporter's message improvement: distinguish "not found" from
  "found but deactivated, will be reactivated".

## 5. Captcha gating (support ticket, "return to Bluesky")

`check_pds` records `captcha_required` from `describeServer.phoneVerificationRequired`
and tries to scrape an hCaptcha site key from `<host>/gate/signup`. For
`bsky.social` the key is never found (logged as `captcha site key: not found`),
but `captcha_required` is still stored on the migration. The verification form only
renders the widget when a site key exists, while `verify_email` refuses any
submission without `h-captcha-response`. The user sees "Please complete the
captcha verification" with no captcha, forever.

`migration_in` (returning to an existing account) never calls `createAccount`, so
a gate code is not needed at all. For `migration_out` to `bsky.social`,
`createAccount` fails with `Authentication Required` regardless (6 cases), because
Bluesky's signup verification cannot be completed by eu-haul.

Fix:

- Only store `captcha_required` for `migration_out`, and only when a site key was
  found.
- In the wizard, block `migration_out` to a PDS that requires phone verification
  without a gatekeeper site key, with a clear explanation, instead of letting the
  user reach email verification.
- Data repair (proposal): clear `captcha_required` on the stuck `migration_in`
  rows so their owners can verify.

## 6. PLC token request through a framing proxy (issue #26)

`GoatService#request_plc_token` calls `post_request(method)` with no data. minisky
0.5.0 then calls `Net::HTTP.post(url, "", headers)`, which sends `Content-Length:
0` and, because no content type is given, Ruby's default
`Content-Type: application/x-www-form-urlencoded`. Cloudflare Tunnel intermittently
re-frames such requests as `Transfer-Encoding: chunked`, and the reference
xrpc-server rejects any no-input procedure that arrives with body framing. The
reporter measured a 35 to 40% failure rate even for truly bodyless requests
through the tunnel, so the client change alone is not sufficient.
`WaitForPlcTokenJob` has no retries and marks the migration failed on the first
error. The same call shape is used for `activateAccount` and `deactivateAccount`.

Fix:

- Add a bodyless POST helper (a `Net::HTTP::Post` with no body and no content
  type) and use it for the three no-input procedures.
- Retry `requestPlcOperationSignature` a few times with backoff on the exact
  `400 InvalidRequest: A request body was provided when none was expected`.
- Document the `disableChunkedEncoding` origin setting for self-hosters behind
  Cloudflare Tunnel.

Frequency: one migration in the last nine days of logs.

## 7. "Email already taken" handling

`createAccount` returned `Email already taken` for a user who already has an
account with that email on the target. `CreateAccountJob` retried three times and
the failure email says "Failed to create..." with no guidance.

Fix: map this error to a non-retried `EmailTakenError` with a message that tells
the user to log in to the existing target account and change its email, or use a
different email for the migration.

## 8. New-account password invalid at the PLC step

One `migration_out` reached `pending_plc` and then failed every PLC submission
with `401 Unauthorized: Invalid identifier or password` when logging in to the
target. Both the stored refresh token and the generated password were rejected,
and no re-authentication happened through eu-haul, which matches the user
performing a password reset on the target PDS (which also revokes sessions).
Users are tempted to do this because the generated password is withheld until
completion and the deactivated account rejects logins in the meantime.

Fix: when the target login fails for a `migration_out`, offer a "re-enter your
new account password" form on the status page (the existing `reauthenticate`
only covers the old PDS), and tell users in the account-created email not to
reset the password on the new server until the migration completes.

## Side findings

### Caddy health check (fixed on the branch, needs a deploy step)

The container has reported `unhealthy` for months. Both probes ever used are
impossible by construction: the repo's `compose.yml.production` and
`Dockerfile.caddy` probe the admin API on `localhost:2019`, which
`Caddyfile.production` turns off (`admin off`); the copy running on the server
probes `http://localhost/`, which the main site redirects to HTTPS, where no
certificate for `localhost` exists. `Caddyfile.production` now has a plain-HTTP
`http://localhost` site answering `/health`, and both health checks probe it.
The unused `2019:2019` port mapping is gone. Rolling this out means copying the
Caddyfile and compose changes to the on-host tree and recreating the Caddy
container.

### Blob uploads rejected with 500 by eurosky.social (mitigated on the branch, root cause with PDS operations)

Numbers for the 7 days to 2026-09-05: 2929 failed upload attempts, 739 blobs
given up after three attempts, 65581 successful uploads. Failures come in
windows of 30 to 60 minutes (for example 2026-09-03 02:00 to 02:40 UTC, and
most of 2026-08-30, 08-31, 09-03) during which 60 to 100 percent of uploads
fail; the same blobs succeed later, and in the worst window a single migration
was uploading with its five parallel threads. The response body was never
logged, so the PDS-side error is unknown; the eurosky-infra troubleshooting
notes say blob uploads are traffic-shaped for every client and that unshaped
burst uploads trip a stream hang in the PDS `uploadBlob` handler, which fits.

User impact was real: the upload path (`UploadBlobsJob`, used whenever a backup
bundle is made) recorded failures under `failed_uploads`, a key nothing reads,
had no reconciliation and no retry, so migrations completed with missing media
(four in the last week, up to 17 files each).

Changes: the error message now carries the first 200 characters of the PDS
response; per-blob attempts go from 3 to 5 with backoff up to 32 s; after the
parallel pass the leftovers are retried one at a time after a 30 s breather;
whatever is still missing is stored under `failed_blobs` (the key the status
page and `RetryFailedBlobsJob` use). The migration does not stall on missing
files: it advances to the PLC step exactly as before, and the leftovers are
retried in the background in up to three passes (15 minutes, then 1 hour,
then 4 hours after the previous one), also after completion. A notice with
the count and a retry button is shown on the status page from the preferences
stage onwards, including the completed page, and the completion email lists
the number of files still in transfer with a link to the page.
`RetryFailedBlobsJob` prefers the local backup-bundle copy over re-downloading
from the old PDS, keeps the bundle intact, and does nothing for a cancelled
migration.

Password rule after completion: changing the new account's password revokes
the sessions the background transfer uses, so a completed migration with files
still in transfer tells the user (completion email, password box, status page)
NOT to change the password until a FINAL mail arrives. `RetryFailedBlobsJob`
sends exactly one of two mails once the migration is completed: "all files
have arrived, you can change the password now" when the list empties, or
"could not be transferred, retry from the status page, keep the password" when
the automatic passes give up. `ActivateAccountJob` starts a fresh background
chain at completion if none is pending, so one of those mails is guaranteed.
The old `failed_blobs_retry_complete` mail (which had no templates and would
have crashed on delivery) is gone.

All 33 new strings exist in every one of the 26 locale files (inserted at the
same anchors as in `en.yml`, placeholders verified). Count-dependent strings
use plain `%{count}` interpolation instead of plural forms so no locale needs
language-specific plural categories.

For PDS operations: the upload shaping or the handler hang is the root cause;
eu-haul's public IP could be exempted from upload shaping the way
`pds_trusted_client_ip` already exempts downloads.

### Rate limiting (no issue)

The earlier note was wrong. `Caddyfile.production` defines `rate_limit` zones
for migration creation (5 per hour per IP), PLC token submission (10 per hour)
and status page polling (60 per minute), and the Caddy image on the server is
built with the plugin (`caddy list-modules` shows `http.handlers.rate_limit`).

### Quick start (issues #13 and #15, fixed on the branch)

`docker-compose.yml` no longer requires the external `u-at-proto_default`
network; `docker-compose.u-at-proto.yml` is an opt-in override for people
running that stack. The dev compose passes `MIGRATION_MASTER_KEY` through as
`LOCKBOX_MASTER_KEY` like production does, `.env.example` defaults to
`RAILS_ENV=development` (it said `production`, which is why the quick start
demanded the key), and README plus `.env.example` say `openssl rand -hex 32`
(Lockbox needs 32 bytes; the old `-hex 16` produces a key Lockbox rejects) and
point at port 3001, which is what the compose file publishes.

### PR #8 (issue #7)

Reviewed, see the notes in the PR review draft; not merged. It is mergeable
against `main` and does not conflict with this branch.

## Relation to the 2026-08-27 branches (checked 2026-09-06)

Five branches were pushed on 2026-08-27, all fallout from the 2026-08-21 DNS
outage, none of them touching the problems above:

| Branch / PR | What it does | Overlap with this branch |
|---|---|---|
| `fix/csp-avatar-images`, PR #22, merged to `main` 2026-09-05 as `6dbebf6` | One-line CSP change in `Caddyfile.production` (avatars from cdn.bsky.app) | Same file, different hunk; this branch applies cleanly on top |
| `fix/handle-resolution-timeouts`, PR #21, open | 10 s budget for handle resolution, `HandleNotFoundError` vs `NetworkError` (404 vs 503), well-known resolution implemented, `/_health` that checks DB and DNS, `rails-controller-testing` gem | Touches `migrations_controller.rb`, `goat_service.rb`, `en.yml` in other regions; merges cleanly. Its `/_health` is the Rails app's dependency check and is deliberately not the container probe, so it complements the Caddy health-check fix rather than replacing it |
| `test/repair-*`, PRs #23, #24, #25, open | Repair `update_plc_job_spec`, `goat_service_spec` (+ helpers), `import_blobs_job_spec` | No file overlap; all 108 repaired examples pass against this branch's code. Running them surfaced one adjustment: `terminal_in_db?` must not treat a row it cannot see as terminal (worker threads in transactional tests) |
| PR #14 (April, external) | Removes the obsolete `version:` line from `docker-compose.yml` | Duplicated by the quick-start fix here; can be closed as superseded |

None of the eight findings or the side findings is addressed by that work.
Production still runs the 2026-07-06 image (`main` at `5530fd4`); the CSP fix
lives in the Caddyfile, which is copied to the host by hand, and had not been
applied there as of 2026-09-05 evening. PR #21 is not deployed.

One hazard found on the way: the CI workflow pushed `:latest` for every branch
push, so on 2026-08-27 `:latest` pointed at PR #21's build for half an hour and
at the spec-repair branches afterwards; a `docker compose pull` in that window
would have deployed a feature branch. The workflow on this branch pushes
`:latest` only from `main` (the `commit-<sha>` tags are unchanged).

PRs #23, #24, #25 and #21 were merged on 2026-09-06 and this branch was
fast-forwarded onto the result (`8cc9538`) without conflicts. On that base the
suite has 54 failing examples on `main` and the same 54 on this branch (31
additional examples, all passing); the remaining failures are the controller
spec that PR #8 rewrites, plus older bitrot in the model, request, upload and
download specs. PR #8 now conflicts with `main` in that spec file.

## Implementation status (2026-09-05)

All eight findings are addressed on the branch:

1. `StuckMigrationSweeperJob` skips unverified migrations.
   `Migration#verify_email!` starts the pipeline only from `pending_account`,
   restarts from the top for a migration that an older sweeper advanced
   without verification (so the transferred data is fresh), and never restarts
   once the PLC operation was submitted. `GoatService#create_account_on_new_pds`
   recognises a deactivated account that the same migration created earlier
   (`progress_data.account_created_at`) and continues.
2. `Migration#advance_with_job!` locks the row and refuses to advance when the
   status changed underneath (raises `Migration::Aborted`); every pipeline job
   rescues `Migration::Aborted` first and stops without retrying; the download,
   upload and import blob loops check `terminal_in_db?` at each progress
   checkpoint and abort; progress is written with `merge_progress!` (an atomic
   JSONB merge) instead of saving a stale hash.
3. Status page reloads on any status change, shows a "last updated" line with
   a refresh link and an error marker, and `UploadBlobsJob` writes
   `blobs_completed` / `bytes_transferred` (the keys the page reads).
   `blob_upload_percentage` also accepts the old `blobs_uploaded` key.
4. Wizard re-asserts the verified host on submit, the custom host field has
   `autocomplete="off"`, and `MigrationsController#target_host_error` rejects
   email addresses, non-hostnames, and a handle-shaped host that does not
   answer `describeServer`.
5. `captcha_required` is stored only for `migration_out` with a site key;
   `verify_email` and the verification view ignore it otherwise; `check_pds`
   reports `captcha_unsupported` and the wizard blocks creating an account on
   such a server; `create` refuses it server-side too.
6. `NoInputRequests#post_request_without_body` (bodyless `Net::HTTP::Post`)
   plus `GoatService#post_no_input` with up to four attempts on the
   body-framing 400, used for `requestPlcOperationSignature`,
   `activateAccount` and `deactivateAccount`. README troubleshooting entry.
7. `GoatService::EmailTakenError` (not retried, `error_code=email_taken`,
   dedicated error-page context and failure email).
8. `POST /migrate/:token/reauthenticate_new_pds` plus a form on the error
   page when the new-account login failed; the rotation-key email now warns
   against resetting the password on the new server before completion.

Specs: `spec/jobs/stuck_migration_sweeper_job_spec.rb`,
`spec/models/migration_pipeline_guards_spec.rb`,
`spec/services/goat_service_no_input_spec.rb`,
`spec/controllers/target_host_validation_spec.rb`, plus one example in
`spec/jobs/upload_blobs_job_spec.rb`. The suite has 153 failures that also
fail on `main` (pre-existing bitrot, see the `test/repair-*` branches); the
branch adds no new failures.

Data repairs: the cancelled-row repair (finding 2) is a one-off SQL script kept
outside the repo; the captcha rows (finding 5) need no repair, their owners can
start a new migration once this is deployed.
