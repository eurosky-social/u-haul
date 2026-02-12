# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2026_02_12_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "migrations", force: :cascade do |t|
    t.string "did", null: false
    t.string "token", null: false
    t.string "email", null: false
    t.string "status", default: "pending_account", null: false
    t.string "old_pds_host", null: false
    t.string "old_handle", null: false
    t.string "new_pds_host", null: false
    t.string "new_handle", null: false
    t.jsonb "progress_data", default: {}
    t.integer "estimated_memory_mb", default: 0
    t.text "encrypted_password"
    t.text "encrypted_plc_token"
    t.datetime "credentials_expires_at"
    t.text "last_error"
    t.integer "retry_count", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "encrypted_invite_code"
    t.datetime "invite_code_expires_at"
    t.boolean "create_backup_bundle", default: true, null: false
    t.string "downloaded_data_path"
    t.string "backup_bundle_path"
    t.datetime "backup_created_at"
    t.datetime "backup_expires_at"
    t.text "rotation_private_key_ciphertext"
    t.string "current_job_step"
    t.integer "current_job_attempt", default: 0
    t.integer "current_job_max_attempts", default: 3
    t.string "migration_type", default: "migration_out", null: false
    t.text "encrypted_plc_otp"
    t.datetime "plc_otp_expires_at"
    t.integer "plc_otp_attempts", default: 0
    t.string "email_verification_token"
    t.datetime "email_verified_at"
    t.text "encrypted_old_access_token"
    t.text "encrypted_old_refresh_token"
    t.text "encrypted_new_access_token"
    t.text "encrypted_new_refresh_token"
    t.index ["backup_expires_at"], name: "index_migrations_on_backup_expires_at"
    t.index ["created_at"], name: "index_migrations_on_created_at"
    t.index ["did"], name: "index_migrations_on_did"
    t.index ["email_verification_token"], name: "index_migrations_on_email_verification_token", unique: true
    t.index ["invite_code_expires_at"], name: "index_migrations_on_invite_code_expires_at"
    t.index ["migration_type"], name: "index_migrations_on_migration_type"
    t.index ["status"], name: "index_migrations_on_status"
    t.index ["token"], name: "index_migrations_on_token", unique: true
  end

end
