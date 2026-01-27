# ImportBlobsJob Implementation

## Overview

`ImportBlobsJob` is the most critical and memory-intensive job in the Eurosky migration pipeline. It handles the transfer of all blobs (images, videos, and other media) from the old PDS to the new PDS with strict memory management and concurrency control.

## File Location

```
app/jobs/import_blobs_job.rb
```

## Key Features

### 1. Concurrency Control
- **Maximum concurrent blob migrations**: 15
- **Enforcement**: Checks count of migrations in `pending_blobs` status
- **Behavior**: If at capacity, re-enqueues job with 30-second delay
- **Rationale**: Prevents memory exhaustion on the migration server

### 2. Sequential Processing
- Blobs are processed **one at a time** (never in parallel)
- Download → Upload → Cleanup cycle for each blob
- Prevents parallel memory spikes
- Ensures predictable memory usage

### 3. Aggressive Memory Management
- **Immediate cleanup**: Deletes local blob file after each upload
- **Periodic GC**: Runs `GC.start` every 50 blobs
- **No caching**: No blobs held in memory longer than necessary
- **File-based transfer**: Uses disk-based streaming, not memory buffers

### 4. Batched Progress Updates
- Database updates occur every **10 blobs** (not every blob)
- Reduces DB write load significantly
- Tracks:
  - `blobs_completed`: Number of blobs transferred
  - `blobs_total`: Total blob count
  - `bytes_transferred`: Total data transferred in bytes
  - `last_progress_update`: Timestamp of last update

### 5. Comprehensive Error Handling
- **Individual blob retries**: 3 attempts with exponential backoff (2s, 4s, 8s)
- **Partial failure tolerance**: Failed blobs logged but don't fail entire job
- **Failed blob tracking**: Stored in `progress_data['failed_blobs']`
- **Job-level retry**: 3 attempts with exponential backoff via ActiveJob

### 6. Memory Estimation
- Uses `MemoryEstimatorService` to estimate total memory usage
- Updates `estimated_memory_mb` field on migration record
- Helps with capacity planning and monitoring

## Data Flow

```
1. Check concurrency (max 15 concurrent blob migrations)
   ↓
2. Mark blobs_started_at timestamp
   ↓
3. Login to old PDS
   ↓
4. List all blobs (cursor-based pagination)
   ↓
5. Estimate memory usage
   ↓
6. Update migration record (blob_count, estimated_memory_mb)
   ↓
7. Login to new PDS
   ↓
8. For each blob (SEQUENTIAL):
   ├─ Download to tmp/goat/{did}/blobs/{cid}
   ├─ Upload to new PDS
   ├─ Delete local file
   ├─ Update progress (every 10th blob)
   └─ Run GC (every 50th blob)
   ↓
9. Mark blobs_completed_at timestamp
   ↓
10. Advance to pending_prefs status
```

## Progress Tracking

The job stores detailed progress information in the `progress_data` JSONB field:

```json
{
  "blobs_started_at": "2026-01-27T10:00:00Z",
  "blobs_completed_at": "2026-01-27T10:45:30Z",
  "blob_count": 450,
  "estimated_memory_mb": 1024,
  "blobs_completed": 450,
  "blobs_total": 450,
  "bytes_transferred": 1073741824,
  "last_progress_update": "2026-01-27T10:45:25Z",
  "failed_blobs": ["bafyreib...", "bafyreic..."]
}
```

## Configuration Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `MAX_CONCURRENT_BLOB_MIGRATIONS` | 15 | Maximum concurrent blob migrations |
| `REQUEUE_DELAY` | 30 seconds | Delay before re-enqueuing when at capacity |
| `MAX_BLOB_RETRIES` | 3 | Maximum retry attempts per blob |
| `PROGRESS_UPDATE_INTERVAL` | 10 | Update DB every N blobs |
| `GC_INTERVAL` | 50 | Run garbage collection every N blobs |

## Error Scenarios

### 1. Individual Blob Failure
- **Behavior**: Logs error, adds to `failed_blobs`, continues with next blob
- **Retry**: 3 attempts with exponential backoff (2s, 4s, 8s)
- **Impact**: Does not fail entire job

### 2. Network Timeout
- **Behavior**: Caught by retry mechanism
- **Retry**: 3 attempts with exponential backoff
- **Impact**: Individual blob or entire job (depending on severity)

### 3. Concurrency Limit Reached
- **Behavior**: Job re-enqueues itself with 30s delay
- **Retry**: Infinite until capacity available
- **Impact**: Job waits, does not fail

### 4. Job Failure
- **Behavior**: Marks migration as `failed` with error message
- **Retry**: 3 attempts via ActiveJob
- **Impact**: Migration enters failed state after all retries exhausted

## Memory Optimization Techniques

### 1. Sequential Processing
```ruby
# NOT THIS (parallel)
blobs.each do |cid|
  Thread.new { download_and_upload(cid) }
end

# THIS (sequential)
blobs.each do |cid|
  download_and_upload(cid)
  cleanup(cid)
end
```

### 2. Immediate Cleanup
```ruby
# Download
blob_path = download_blob_with_retry(goat, cid)

# Upload
upload_blob_with_retry(goat, blob_path)

# Delete immediately (not at end of job)
FileUtils.rm_f(blob_path)
```

### 3. Batched Database Updates
```ruby
# NOT THIS (every blob)
blobs.each do |cid|
  process(cid)
  update_db(migration)  # 450 DB writes
end

# THIS (every 10 blobs)
blobs.each_with_index do |cid, i|
  process(cid)
  update_db(migration) if (i + 1) % 10 == 0  # 45 DB writes
end
```

### 4. Explicit Garbage Collection
```ruby
blobs.each_with_index do |cid, i|
  process(cid)
  GC.start if (i + 1) % 50 == 0  # Force memory reclamation
end
```

## Integration Points

### GoatService Methods Used
- `login_old_pds` - Authenticate with source PDS
- `login_new_pds` - Authenticate with destination PDS
- `list_blobs(cursor)` - List blobs with pagination
- `download_blob(cid)` - Download single blob
- `upload_blob(blob_path)` - Upload single blob

### Migration Model Methods Used
- `advance_to_pending_prefs!` - Move to next pipeline stage
- `mark_failed!(error)` - Mark migration as failed
- `save!` - Persist progress updates

### MemoryEstimatorService Methods Used
- `estimate(blob_list)` - Estimate memory usage from blob list

## Monitoring and Debugging

### Key Log Messages
```ruby
# Start
"Starting blob import for migration EURO-ABC12345 (DID: did:plc:...)"

# Concurrency limit
"Concurrency limit reached (15), re-enqueuing in 30s"

# Progress
"Found 450 total blobs to transfer"
"Estimated memory: 1024 MB for 450 blobs"
"Transferred blob 10/450: bafyreib... (2.4 MB)"

# Completion
"Blob transfer complete: 450/450 successful"
"Total data transferred: 1.05 GB"

# Errors
"Failed to transfer 2 blobs: bafyreib..., bafyreic..."
"Blob import failed for migration 123: Network timeout"
```

### Monitoring Queries
```ruby
# Check concurrent blob migrations
Migration.where(status: :pending_blobs).count

# Check in-progress migrations with details
Migration.where(status: :pending_blobs).pluck(:token, :estimated_memory_mb)

# Check failed blobs for a migration
migration.progress_data['failed_blobs']

# Calculate success rate
completed = migration.progress_data['blobs_completed']
total = migration.progress_data['blobs_total']
success_rate = (completed.to_f / total * 100).round(2)
```

## Performance Characteristics

### Typical Migration (1000 blobs, 2 GB)
- **Duration**: 15-30 minutes
- **Memory usage**: ~150 MB (plus blob overhead)
- **DB writes**: ~100 (progress updates)
- **Network transfers**: 2000 (1000 downloads + 1000 uploads)

### Large Migration (10,000 blobs, 20 GB)
- **Duration**: 2.5-5 hours
- **Memory usage**: ~150 MB (constant, thanks to cleanup)
- **DB writes**: ~1000 (progress updates)
- **Network transfers**: 20,000 (10,000 downloads + 10,000 uploads)

## Testing Considerations

### Unit Tests
- Mock `GoatService` methods
- Test concurrency limit enforcement
- Test progress update batching
- Test retry logic
- Test error handling

### Integration Tests
- Use small test accounts (10-20 blobs)
- Verify file cleanup
- Verify memory usage stays constant
- Verify failed blobs don't fail job
- Verify progress tracking accuracy

### Load Tests
- Run 15 concurrent migrations
- Monitor memory usage
- Verify concurrency limit enforcement
- Verify re-enqueue behavior

## Future Enhancements

### Potential Improvements
1. **Parallel blob transfer** (with strict memory limits)
2. **Blob deduplication** (check if blob already exists)
3. **Resume capability** (skip already-transferred blobs)
4. **Bandwidth throttling** (prevent network saturation)
5. **Progress webhooks** (real-time notifications)
6. **Blob verification** (checksum validation)
7. **Partial batch commits** (upload in chunks)

### Monitoring Enhancements
1. **Prometheus metrics** (transfer rate, error rate)
2. **Grafana dashboards** (real-time progress)
3. **Alerting** (stuck jobs, high failure rate)
4. **Capacity predictions** (estimated completion time)

## Troubleshooting

### Job Stuck in Queue
- Check if 15 migrations already in `pending_blobs` status
- Check Sidekiq queue depth: `Sidekiq::Queue.new('migrations').size`
- Check Sidekiq workers: `Sidekiq::Workers.new.size`

### High Memory Usage
- Verify `GC_INTERVAL` is set correctly (50 blobs)
- Check if local files are being cleaned up
- Verify no memory leaks in `GoatService`
- Reduce `MAX_CONCURRENT_BLOB_MIGRATIONS` if needed

### Slow Transfer Speed
- Check network bandwidth to both PDS servers
- Verify no rate limiting on PDS endpoints
- Consider reducing `MAX_CONCURRENT_BLOB_MIGRATIONS` to reduce contention
- Check if old PDS is under load

### High Failure Rate
- Check old PDS availability and response times
- Check new PDS disk space and upload limits
- Verify authentication tokens are valid
- Check network stability between migration server and PDS servers

## Related Files

- `app/models/migration.rb` - Migration model with progress tracking
- `app/services/goat_service.rb` - ATProto client wrapper
- `app/services/memory_estimator_service.rb` - Memory estimation
- `app/jobs/import_repo_job.rb` - Previous step (repository import)
- `app/jobs/import_prefs_job.rb` - Next step (preferences import)
