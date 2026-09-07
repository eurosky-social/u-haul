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

ActiveRecord::Schema[7.1].define(version: 2026_09_07_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "blob_transfer_stats", force: :cascade do |t|
    t.bigint "migration_id"
    t.string "job_name", null: false
    t.string "pass", null: false
    t.string "source_host"
    t.string "target_host"
    t.string "target_pds_version"
    t.datetime "started_at", null: false
    t.datetime "finished_at"
    t.integer "duration_ms"
    t.integer "blobs_attempted", default: 0, null: false
    t.integer "blobs_succeeded", default: 0, null: false
    t.integer "blobs_failed", default: 0, null: false
    t.integer "upload_attempts", default: 0, null: false
    t.bigint "bytes_transferred", default: 0, null: false
    t.integer "throughput_bps"
    t.integer "upload_bps_p50"
    t.integer "upload_ms_p50"
    t.integer "upload_ms_p95"
    t.integer "upload_ms_max"
    t.jsonb "outcome_counts", default: {}, null: false
    t.jsonb "failure_samples", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_blob_transfer_stats_on_created_at"
    t.index ["migration_id"], name: "index_blob_transfer_stats_on_migration_id"
    t.index ["outcome_counts"], name: "index_blob_transfer_stats_on_outcome_counts", using: :gin
    t.index ["target_pds_version"], name: "index_blob_transfer_stats_on_target_pds_version"
  end

  create_table "legal_consents", force: :cascade do |t|
    t.string "did", null: false
    t.string "migration_token"
    t.bigint "tos_snapshot_id", null: false
    t.bigint "privacy_policy_snapshot_id", null: false
    t.text "ip_address_ciphertext"
    t.datetime "accepted_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["did"], name: "index_legal_consents_on_did"
    t.index ["migration_token"], name: "index_legal_consents_on_migration_token"
    t.index ["privacy_policy_snapshot_id"], name: "index_legal_consents_on_privacy_policy_snapshot_id"
    t.index ["tos_snapshot_id"], name: "index_legal_consents_on_tos_snapshot_id"
  end

  create_table "legal_snapshots", force: :cascade do |t|
    t.string "document_type", null: false
    t.string "content_hash", null: false
    t.text "rendered_content", null: false
    t.string "version_label", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["document_type", "content_hash"], name: "index_legal_snapshots_on_document_type_and_content_hash", unique: true
    t.index ["document_type", "created_at"], name: "index_legal_snapshots_on_document_type_and_created_at"
  end

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
    t.string "error_code"
    t.string "target_pds_contact_email"
    t.string "locale", default: "en", null: false
    t.index ["backup_expires_at"], name: "index_migrations_on_backup_expires_at"
    t.index ["created_at"], name: "index_migrations_on_created_at"
    t.index ["did"], name: "index_migrations_on_did"
    t.index ["email_verification_token"], name: "index_migrations_on_email_verification_token", unique: true
    t.index ["error_code"], name: "index_migrations_on_error_code"
    t.index ["invite_code_expires_at"], name: "index_migrations_on_invite_code_expires_at"
    t.index ["migration_type"], name: "index_migrations_on_migration_type"
    t.index ["status"], name: "index_migrations_on_status"
    t.index ["token"], name: "index_migrations_on_token", unique: true
  end

  create_table "pds_consents", force: :cascade do |t|
    t.string "did", null: false
    t.string "migration_token"
    t.string "pds_host", null: false
    t.string "tos_url"
    t.string "privacy_policy_url"
    t.text "ip_address_ciphertext"
    t.datetime "accepted_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["did"], name: "index_pds_consents_on_did"
    t.index ["migration_token"], name: "index_pds_consents_on_migration_token"
    t.index ["pds_host"], name: "index_pds_consents_on_pds_host"
  end

  add_foreign_key "blob_transfer_stats", "migrations", on_delete: :nullify
  add_foreign_key "legal_consents", "legal_snapshots", column: "privacy_policy_snapshot_id"
  add_foreign_key "legal_consents", "legal_snapshots", column: "tos_snapshot_id"
end
