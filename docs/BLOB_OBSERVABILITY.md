# Blob transfer observability

The blob stage is where migrations fail. Until now the only record of *how*
they failed was free text in the container log, which rotates — so questions
like "did the PDS upgrade change our success rate?", "are we seeing 500s or
timeouts?" and "how fast are uploads actually going?" could only be answered
for a few days after the fact, by grepping.

Every blob pass now writes a `blob_transfer_stats` row. The rows outlive the
migrations they came from, so the questions stay answerable.

## What a "pass" is

One sweep over a set of blobs. A migration normally makes one, and only the
leftovers reach the later ones:

| Pass | Written by | What it means |
|------|-----------|---------------|
| `parallel` | `UploadBlobsJob`, `ImportBlobsJob` | The main sweep, 5 worker threads |
| `sequential` | `UploadBlobsJob` | Second pass, one blob at a time, after a 30s breather |
| `reconcile` | `ImportBlobsJob` | Gap-filling against `com.atproto.repo.listMissingBlobs` |
| `retry` | `RetryFailedBlobsJob` | Background passes (15 min, +1h, +4h) and manual retries |

Splitting them matters: a `retry` pass runs against a PDS that already refused
those blobs once, so its success rate answers a different question from the
main sweep's. Averaging them hides both.

## Reading the numbers

```bash
bundle exec rake "blobs:stats"        # last 7 days
bundle exec rake "blobs:stats[30]"    # last 30 days
bundle exec rake "blobs:failures[7]"  # what the failures actually were
```

Quote the task name — zsh eats the square brackets otherwise.

```
  target          PDS version    passes  migrations  blobs  ok   failed  success  upload p50  p95 ms
  --------------  -------------  ------  ----------  -----  ---  ------  -------  ----------  -------
  eurosky.social  0.5.10         8       1           800    592  208     74.0%    1.19 MB/s   118,000
  bsky.social     88465e2115f5…  5       1           500    495  5       99.0%    0.07 MB/s   5,262
  eurosky.social  0.5.29         4       1           400    400  0       100.0%   11.25 MB/s  420
```

- **`target`** — migrations run in both directions, so rows are per target PDS.
  Mixing the two says nothing useful: the PDS we operate and the one a user is
  leaving for have separate stories. The `bsky.social` row also shows why the
  version column is not always a version — its `/xrpc/_health` answers with a
  git SHA, truncated here, which is a stable deployment identifier rather than
  something you can read.

- **`success`** — the share of blobs a pass was asked to move that it moved.
  A pass with nothing to do reports `-` rather than 100%, so empty passes
  cannot flatter the average.
- **`upload p50`** — median throughput of a *single* upload. This is the
  interesting one for edge shaping: a hard ceiling near **1.19 MB/s** is the
  HAProxy `blob-upload-stream` filter (10 Mbit/s per connection), not a slow
  network. Unshaped uploads sit an order of magnitude higher.
- **`p95 ms`** — how long the slow uploads take. Values pinned near a timeout
  ceiling mean uploads are *stalling* rather than being refused.

`target_pds_version` comes from the target's `/xrpc/_health`, read once per
job. Together with `target_host` it is what makes a before/after comparison
possible: when the PDS image is bumped, the rows either side of the bump line
up next to each other without anyone having to remember the date.

## Outcome buckets

`outcome_counts` holds flat `"<phase>.<outcome>"` keys, so it stays queryable
in plain SQL:

| Bucket | Raised as | Means |
|--------|-----------|-------|
| `upload.ok` / `download.ok` | — | Transferred |
| `upload.http_500` (any code) | `NetworkError` with `http_status` | The PDS answered, and said no |
| `upload.timeout` | `TimeoutError` | The PDS went quiet — the signature of a wedged blob handler |
| `upload.rate_limited` | `RateLimitError` | HTTP 429, kept separate from other 4xx |
| `upload.error` | anything else | Connection reset, DNS, etc. — exact class is in `failure_samples` |

Telling a timeout apart from a 500 is the point. They have different causes
and different fixes, and before this they were both just a `NetworkError` with
a sentence in it.

`upload_attempts` counts every try including retries, while `blobs_attempted`
counts distinct blobs — so `upload_attempts / blobs_attempted` is retry
pressure. A pass fighting the target for every file shows up as 2-3.

## SQL

```sql
-- Success rate per target PDS version, last 30 days. Group by the host too:
-- migrations run both ways, and two targets can report the same version.
SELECT target_host, target_pds_version,
       SUM(blobs_attempted) AS attempted,
       SUM(blobs_succeeded) AS succeeded,
       ROUND(100.0 * SUM(blobs_succeeded) / NULLIF(SUM(blobs_attempted), 0), 1) AS pct
FROM blob_transfer_stats
WHERE created_at > now() - interval '30 days'
GROUP BY 1, 2 ORDER BY attempted DESC;

-- How often did uploads stall rather than get refused?
SELECT date_trunc('day', created_at) AS day,
       SUM((outcome_counts->>'upload.timeout')::int)  AS timeouts,
       SUM((outcome_counts->>'upload.http_500')::int) AS server_errors
FROM blob_transfer_stats
WHERE created_at > now() - interval '14 days'
GROUP BY 1 ORDER BY 1;
```

## Loki

Each pass also emits one line with a stable prefix and a JSON payload, so the
same numbers are in Grafana without waiting for anyone to run a rake task:

```
blob_transfer_summary {"migration_id":123,"job":"UploadBlobsJob","pass":"parallel",...}
```

```logql
{service_name="eurosky-sidekiq"}
  |= "blob_transfer_summary"
  | regexp "blob_transfer_summary (?P<payload>\\{.*\\})"
  | line_format "{{.payload}}" | json
  | unwrap upload_bps_p50
```

Two things worth knowing about that query:

- The Rails logger prefixes each line with severity and timestamp, so the JSON
  has to be extracted before `| json` will parse it — hence the `regexp` step.
- Blob passes run on the `migrations` queue, so they are in the plain sidekiq
  container, not `eurosky-sidekiq-critical`.

This pipeline is not automatic — it exists only because the euhaul host ships
its journal. That took three changes in `eurosky-infra`, all on the
`fix/blob-transfer-bugs` branch there:

| Change | Why |
|---|---|
| `alloy` + `journald` roles added to `playbooks/site/euhaul.yml` | The host ran neither; nothing left the box |
| `alloy_push_*` / `alloy_loki_url` in `group_vars/identity_euhaul` | Endpoints, pointed at the platform log store |
| `tag:identity-euhaul` added to `telemetry_shipper_tags` | Tailscale ACL: without it the shipper is installed but blocked |

The euhaul compose also now sets a journald `tag:` log-opt per service. Without
it Docker defaults the tag to the container ID, which is what Alloy relabels
into `service_name` — so the label would have been a hex string.

Until that infra branch is merged and the host converged, this section
describes something that does not exist yet: use the rake tasks and SQL above,
which read the database directly and need no pipeline at all.

## Retention

`blob_transfer_stats.migration_id` is nullable and its foreign key nullifies
on delete. `CleanupOldMigrationsJob` destroys completed migrations after 2 days
and failed ones after 7, and anything cascaded from `migrations` would be gone
long before it could answer a month-over-month question. Nothing in the table
identifies a user: no token, no DID, no email — only hostnames, counts and
timings.

## Related

- `app/services/blob_transfer_telemetry.rb` — the collector
- `app/models/blob_transfer_stat.rb` — the row and its aggregation
- [IMPORT_BLOBS_JOB.md](IMPORT_BLOBS_JOB.md) — the transfer itself
