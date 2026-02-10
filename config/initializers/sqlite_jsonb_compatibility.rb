# SQLite compatibility for PostgreSQL's jsonb type
# SQLite doesn't have jsonb, so we alias it to json (stored as text)

if defined?(ActiveRecord::ConnectionAdapters::SQLite3Adapter)
  module ActiveRecord
    module ConnectionAdapters
      class SQLite3::TableDefinition
        # Add jsonb method that delegates to json for SQLite
        def jsonb(*args, **options)
          # SQLite stores JSON as text, but Rails can still serialize/deserialize it
          json(*args, **options)
        end
      end
    end
  end
end
