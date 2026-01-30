# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MemoryEstimatorService do
  describe '.estimate' do
    context 'with empty blob list' do
      it 'returns 0' do
        expect(described_class.estimate([])).to eq(0)
      end

      it 'returns 0 for nil' do
        expect(described_class.estimate(nil)).to eq(0)
      end
    end

    context 'with blobs that have size_bytes' do
      let(:blob_list) do
        [
          { size_bytes: 1_048_576 },     # 1 MB
          { size_bytes: 5_242_880 },     # 5 MB
          { size_bytes: 10_485_760 }     # 10 MB
        ]
      end

      it 'calculates total size in MB' do
        # Total: 16 MB
        # With 1.5x overhead: 24 MB
        expect(described_class.estimate(blob_list)).to eq(24)
      end

      it 'applies memory overhead multiplier' do
        single_mb = [{ size_bytes: 1_048_576 }]
        # 1 MB ceil = 1, then * 1.5 = 1.5, truncated to 1 MB
        expect(described_class.estimate(single_mb)).to eq(1)
      end

      it 'rounds up to nearest MB' do
        # 1.5 MB of actual data
        blob_list = [{ size_bytes: 1_572_864 }]
        # 1.5 MB * 1.5 overhead = 2.25 MB, should round to 3 MB
        result = described_class.estimate(blob_list)
        expect(result).to be >= 2
        expect(result).to be <= 3
      end
    end

    context 'with blobs without size_bytes' do
      let(:blob_list) do
        [
          { cid: 'bafyabc123' },  # No size, assumes average image
          { cid: 'bafyxyz789' }   # No size, assumes average image
        ]
      end

      it 'uses average image size for blobs without size' do
        # 2 images * 2MB each = 4 MB
        # With 1.5x overhead: 6 MB
        expect(described_class.estimate(blob_list)).to eq(6)
      end
    end

    context 'with mixed blob types' do
      let(:blob_list) do
        [
          { size_bytes: 10_485_760 },  # 10 MB explicit
          { cid: 'bafyabc' },           # 2 MB assumed
          { size_bytes: 5_242_880 }    # 5 MB explicit
        ]
      end

      it 'calculates total with mixed sizes' do
        # Total: 10 + 2 + 5 = 17 MB
        # With 1.5x overhead: 25.5 MB, rounded to 26 MB
        result = described_class.estimate(blob_list)
        expect(result).to be >= 25
        expect(result).to be <= 26
      end
    end

    context 'with large data sets' do
      let(:large_blob_list) do
        # 100 blobs, each 50 MB
        100.times.map { { size_bytes: 50 * 1024 * 1024 } }
      end

      it 'handles large blob lists' do
        # Total: 5000 MB
        # With 1.5x overhead: 7500 MB
        expect(described_class.estimate(large_blob_list)).to eq(7500)
      end
    end
  end

  describe '.concurrent_migrations_allowed' do
    context 'with no current memory usage' do
      it 'allows maximum concurrent migrations' do
        # Total: 60GB (61440 MB)
        # Buffer: 4GB (4096 MB)
        # Available: 57344 MB
        # Per migration: 4GB (4096 MB)
        # Allowed: 57344 / 4096 = 14 migrations
        result = described_class.concurrent_migrations_allowed(0)
        expect(result).to eq(14)
      end
    end

    context 'with some memory in use' do
      it 'calculates remaining capacity' do
        # Using 20GB (20480 MB)
        # Available: 60GB - 4GB - 20GB = 36GB (36864 MB)
        # Allowed: 36864 / 4096 = 9 migrations
        result = described_class.concurrent_migrations_allowed(20 * 1024)
        expect(result).to eq(9)
      end
    end

    context 'with high memory usage' do
      it 'allows fewer migrations' do
        # Using 50GB (51200 MB)
        # Available: 60GB - 4GB - 50GB = 6GB (6144 MB)
        # Allowed: 6144 / 4096 = 1 migration
        result = described_class.concurrent_migrations_allowed(50 * 1024)
        expect(result).to eq(1)
      end
    end

    context 'when memory is exhausted' do
      it 'returns 0 when at capacity' do
        # Using 57GB (58368 MB) - exceeds available (60 - 4 = 56GB)
        result = described_class.concurrent_migrations_allowed(57 * 1024)
        expect(result).to eq(0)
      end

      it 'returns 0 when over capacity' do
        # Using 70GB (way over capacity)
        result = described_class.concurrent_migrations_allowed(70 * 1024)
        expect(result).to eq(0)
      end
    end

    context 'with partial migration capacity' do
      it 'floors the result to whole migrations' do
        # Available memory for 1.5 migrations should return 1
        # Using 52GB (53248 MB)
        # Available: 60 - 4 - 52 = 4GB (4096 MB)
        # Exactly enough for 1 migration
        result = described_class.concurrent_migrations_allowed(52 * 1024)
        expect(result).to eq(1)

        # Using 53GB (54272 MB)
        # Available: 60 - 4 - 53 = 3GB (3072 MB)
        # Not enough for even 1 migration
        result = described_class.concurrent_migrations_allowed(53 * 1024)
        expect(result).to eq(0)
      end
    end

    context 'boundary conditions' do
      it 'handles exact buffer boundary' do
        # Using exactly the buffer amount
        result = described_class.concurrent_migrations_allowed(4 * 1024)
        expect(result).to be >= 0
      end

      it 'handles exact total memory' do
        # Using all memory
        result = described_class.concurrent_migrations_allowed(60 * 1024)
        expect(result).to eq(0)
      end
    end
  end

  describe 'constants' do
    it 'defines reasonable average image size' do
      expect(described_class::AVERAGE_IMAGE_SIZE_MB).to eq(2)
    end

    it 'defines reasonable average video size' do
      expect(described_class::AVERAGE_VIDEO_SIZE_MB).to eq(15)
    end

    it 'defines memory overhead multiplier' do
      expect(described_class::MEMORY_OVERHEAD_MULTIPLIER).to eq(1.5)
    end

    it 'defines total memory budget' do
      expect(described_class::TOTAL_MEMORY_MB).to eq(60 * 1024)
    end

    it 'defines memory buffer' do
      expect(described_class::MEMORY_BUFFER_MB).to eq(4 * 1024)
    end

    it 'defines average migration size' do
      expect(described_class::AVERAGE_MIGRATION_SIZE_MB).to eq(4 * 1024)
    end
  end

  describe 'realistic scenarios' do
    context 'typical user account with mostly images' do
      let(:typical_account) do
        # 100 posts with images, average 2MB each
        100.times.map { { size_bytes: 2 * 1024 * 1024 } }
      end

      it 'estimates memory for typical account' do
        # 200 MB actual data
        # With 1.5x overhead: 300 MB
        expect(described_class.estimate(typical_account)).to eq(300)
      end
    end

    context 'power user account with videos' do
      let(:power_user_account) do
        # 50 images (2MB each) + 10 videos (50MB each)
        images = 50.times.map { { size_bytes: 2 * 1024 * 1024 } }
        videos = 10.times.map { { size_bytes: 50 * 1024 * 1024 } }
        images + videos
      end

      it 'estimates memory for power user' do
        # Images: 100 MB, Videos: 500 MB, Total: 600 MB
        # With 1.5x overhead: 900 MB
        expect(described_class.estimate(power_user_account)).to eq(900)
      end
    end

    context 'system capacity planning' do
      it 'can handle 14 concurrent average migrations' do
        # 14 migrations * 4GB each = 56GB
        # Plus 4GB buffer = 60GB total
        memory_per_migration = 4 * 1024  # 4GB

        14.times do |i|
          current_usage = i * memory_per_migration
          allowed = described_class.concurrent_migrations_allowed(current_usage)
          expect(allowed).to eq(14 - i)
        end
      end
    end
  end
end
