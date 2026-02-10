class FixProgressDataColumnType < ActiveRecord::Migration[7.1]
  def up
    # Only needed for databases that were created with the wrong column type
    # This migration converts text to jsonb on PostgreSQL
    if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      # Check if column is currently text
      column = connection.columns(:migrations).find { |c| c.name == 'progress_data' }

      if column.sql_type == 'text'
        # Change from text to jsonb, preserving data
        change_column :migrations, :progress_data, :jsonb, using: 'progress_data::jsonb', default: {}
      end
    end
    # SQLite keeps text column with serialize in model
  end

  def down
    # Revert to text if needed (shouldn't normally run this)
    if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      change_column :migrations, :progress_data, :text, default: '{}'
    end
  end
end
