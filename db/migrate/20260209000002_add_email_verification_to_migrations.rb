class AddEmailVerificationToMigrations < ActiveRecord::Migration[7.1]
  def change
    add_column :migrations, :email_verification_token, :string
    add_column :migrations, :email_verified_at, :datetime
    add_index :migrations, :email_verification_token, unique: true
  end
end
