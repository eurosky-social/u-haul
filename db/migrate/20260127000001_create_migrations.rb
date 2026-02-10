class CreateMigrations < ActiveRecord::Migration[7.1]
  def change
    create_table :migrations do |t|
      # Identity
      t.string :did, null: false
      t.string :token, null: false
      t.string :email, null: false

      # Status tracking
      t.string :status, null: false, default: 'pending_account'

      # PDS information
      t.string :old_pds_host, null: false
      t.string :old_handle, null: false
      t.string :new_pds_host, null: false
      t.string :new_handle, null: false

      # Progress tracking (JSON)
      # PostgreSQL: native jsonb column with default {}
      # SQLite: text column with default "{}" and serialize in model
      if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
        t.jsonb :progress_data, default: {}
      else
        t.text :progress_data, default: "{}"
      end

      # Memory management
      t.integer :estimated_memory_mb, default: 0

      # Encrypted credentials (short-lived)
      t.text :encrypted_password
      t.text :encrypted_plc_token
      t.datetime :credentials_expires_at

      # Error tracking
      t.text :last_error
      t.integer :retry_count, default: 0

      t.timestamps
    end

    add_index :migrations, :did, unique: true
    add_index :migrations, :token, unique: true
    add_index :migrations, :status
    add_index :migrations, :created_at
  end
end
