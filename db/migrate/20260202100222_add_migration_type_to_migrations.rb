class AddMigrationTypeToMigrations < ActiveRecord::Migration[7.1]
  def change
    add_column :migrations, :migration_type, :string, default: 'migration_out', null: false
    add_index :migrations, :migration_type
  end
end
