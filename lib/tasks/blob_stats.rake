# frozen_string_literal: true

# Formatting helpers for the reports below. Namespaced rather than defined at
# top level: methods defined directly in a .rake file land on Object and would
# be visible to every other task in the app.
module BlobStatsReport
  module_function

  def number(value)
    value.to_i.to_s.reverse.scan(/\d{1,3}/).join(',').reverse
  end

  def percent(fraction)
    return '-' if fraction.nil?

    format('%.1f%%', fraction * 100)
  end

  def bytes_per_second(bps)
    return '-' if bps.nil? || bps.to_i.zero?

    format('%.2f MB/s', bps.to_f / (1024 * 1024))
  end

  def table(headers, rows)
    widths = headers.each_with_index.map do |header, index|
      [header.length, *rows.map { |row| row[index].to_s.length }].max
    end

    render = ->(cells) { '  ' + cells.each_with_index.map { |c, i| c.to_s.ljust(widths[i]) }.join('  ') }

    [render.call(headers), render.call(widths.map { |width| '-' * width }),
     *rows.map { |row| render.call(row) }].join("\n")
  end
end

# Reports over the BlobTransferStat rows.
#
#   bundle exec rake "blobs:stats"          # last 7 days
#   bundle exec rake "blobs:stats[30]"      # last 30 days
#   bundle exec rake "blobs:failures[7]"    # what the failures actually were
#
# Quote the task name: zsh eats the square brackets otherwise.
namespace :blobs do
  desc 'Blob transfer success rate and throughput, grouped by target PDS version'
  task :stats, [:days] => :environment do |_task, args|
    days = (args[:days] || 7).to_i
    since = days.days.ago
    summary = BlobTransferStat.summary(since: since)

    puts
    puts "Blob transfers, last #{days} day#{'s' unless days == 1} (since #{since.to_date})"
    puts

    if summary.empty?
      puts '  No blob transfers recorded in this window.'
      puts
      next
    end

    rows = summary.map do |entry|
      [
        entry[:target_pds_version].to_s,
        entry[:passes].to_s,
        entry[:migrations].to_s,
        BlobStatsReport.number(entry[:blobs_attempted]),
        BlobStatsReport.number(entry[:blobs_succeeded]),
        BlobStatsReport.number(entry[:blobs_failed]),
        BlobStatsReport.percent(entry[:success_rate]),
        BlobStatsReport.bytes_per_second(entry[:upload_bps_p50]),
        entry[:upload_ms_p95] ? BlobStatsReport.number(entry[:upload_ms_p95]) : '-'
      ]
    end

    headers = ['PDS version', 'passes', 'migrations', 'blobs', 'ok', 'failed',
               'success', 'upload p50', 'p95 ms']
    puts BlobStatsReport.table(headers, rows)

    puts
    puts '  Reading it: `success` is the share of blobs a pass was asked to move that it moved.'
    puts '  `upload p50` is the median speed of a single upload - a hard ceiling near'
    puts '  1.19 MB/s means an upload shaper in front of the PDS, not a slow network.'
    puts
  end

  desc 'Failure profile for blob transfers'
  task :failures, [:days] => :environment do |_task, args|
    days = (args[:days] || 7).to_i
    since = days.days.ago
    stats = BlobTransferStat.since(since).to_a

    puts
    puts "Blob transfer failures, last #{days} day#{'s' unless days == 1}"
    puts

    if stats.empty?
      puts '  No blob transfers recorded in this window.'
      puts
      next
    end

    outcomes = Hash.new(0)
    stats.each { |stat| stat.outcome_counts.each { |key, count| outcomes[key] += count } }
    failures = outcomes.reject { |key, _| key.end_with?('.ok') }.sort_by { |_, count| -count }

    if failures.empty?
      puts '  No failures recorded - every attempt succeeded.'
    else
      total = outcomes.values.sum
      failures.each do |key, count|
        puts format('  %-28s %8s  %6s of all attempts', key, BlobStatsReport.number(count), BlobStatsReport.percent(count.to_f / total))
      end
    end

    samples = stats.flat_map(&:failure_samples).last(10)
    if samples.any?
      puts
      puts '  Most recent failures:'
      samples.each do |sample|
        puts format('    %-14s %-10s %6s ms  %s',
                    sample['outcome'], sample['phase'], sample['ms'],
                    sample['message'].to_s[0, 90])
      end
    end
    puts
  end
end
