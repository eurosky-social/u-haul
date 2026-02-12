class AddNewPdsTokensToMigrations < ActiveRecord::Migration[7.1]
  def change
    add_column :migrations, :encrypted_new_access_token, :text
    add_column :migrations, :encrypted_new_refresh_token, :text
  end
end
