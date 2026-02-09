class AddPlcOtpToMigrations < ActiveRecord::Migration[7.1]
  def change
    add_column :migrations, :encrypted_plc_otp, :text
    add_column :migrations, :plc_otp_expires_at, :datetime
    add_column :migrations, :plc_otp_attempts, :integer, default: 0
  end
end
