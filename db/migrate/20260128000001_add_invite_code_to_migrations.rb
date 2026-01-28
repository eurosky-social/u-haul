# frozen_string_literal: true

class AddInviteCodeToMigrations < ActiveRecord::Migration[7.1]
  def change
    add_column :migrations, :encrypted_invite_code, :text
    add_column :migrations, :invite_code_expires_at, :datetime

    # Add index for expired invite codes cleanup
    add_index :migrations, :invite_code_expires_at
  end
end
