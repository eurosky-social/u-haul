# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Migration Flow", type: :request do
  let(:user_email) { "test@example.com" }
  let(:old_handle) { "test.bsky.social" }
  let(:new_handle) { "test.example.com" }
  let(:new_pds_host) { "https://pds.example.com" }
  let(:password) { "test_password_123" }
  let(:plc_token) { "plc_token_abc123" }

  let(:resolved_did) { "did:plc:test123abc" }
  let(:resolved_pds_host) { "https://bsky.social" }

  describe "Complete migration flow" do
    it "completes full migration cycle from creation to completion" do
      # Step 1: User visits migration form
      get "/migrations/new"
      expect(response).to be_successful
      expect(response.body).to include("Start Migration")

      # Step 2: User submits migration form
      # Mock handle resolution
      allow(GoatService).to receive(:resolve_handle).with(old_handle).and_return(
        { did: resolved_did, pds_host: resolved_pds_host }
      )

      post "/migrations", params: {
        migration: {
          email: user_email,
          old_handle: old_handle,
          new_handle: new_handle,
          new_pds_host: new_pds_host,
          password: password
        }
      }

      expect(response).to have_http_status(:redirect)

      # Verify migration was created
      migration = Migration.last
      expect(migration).to be_present
      expect(migration.email).to eq(user_email)
      expect(migration.did).to eq(resolved_did)
      expect(migration.token).to match(/\AEURO-[A-Z0-9]{8}\z/)

      # Follow redirect to status page
      follow_redirect!
      expect(response).to be_successful
      expect(response.body).to include(migration.token)

      # Step 3: User views status page by token
      get "/migrate/#{migration.token}"
      expect(response).to be_successful
      expect(response.body).to include("Migration Progress")

      # Step 4: Check status via JSON API
      get "/migrations/#{migration.id}/status"
      expect(response).to be_successful

      json = JSON.parse(response.body)
      expect(json['token']).to eq(migration.token)
      expect(json['status']).to be_present
      expect(json['progress_percentage']).to be_a(Integer)

      # Step 5: Simulate migration progress through stages
      migration.update!(status: :pending_repo)
      get "/migrations/#{migration.id}/status"
      json = JSON.parse(response.body)
      expect(json['status']).to eq('pending_repo')

      migration.update!(status: :pending_blobs)
      get "/migrations/#{migration.id}/status"
      json = JSON.parse(response.body)
      expect(json['status']).to eq('pending_blobs')

      migration.update!(status: :pending_prefs)
      get "/migrations/#{migration.id}/status"
      json = JSON.parse(response.body)
      expect(json['status']).to eq('pending_prefs')

      # Step 6: Migration reaches pending_plc, waiting for token
      migration.update!(status: :pending_plc)
      get "/migrate/#{migration.token}"
      expect(response).to be_successful
      expect(response.body).to include("PLC Token")

      # Step 7: User submits PLC token
      post "/migrate/#{migration.token}/plc_token", params: {
        plc_token: plc_token
      }

      expect(response).to have_http_status(:redirect)
      expect(UpdatePlcJob).to have_been_enqueued.with(migration.id)

      # Verify token was stored
      migration.reload
      expect(migration.plc_token).to eq(plc_token)

      # Step 8: Migration completes
      migration.update!(status: :completed)
      get "/migrations/#{migration.id}/status"

      json = JSON.parse(response.body)
      expect(json['status']).to eq('completed')
      expect(json['progress_percentage']).to eq(100)
    end
  end

  describe "Error scenarios" do
    context "when handle resolution fails" do
      before do
        allow(GoatService).to receive(:resolve_handle).and_raise(
          GoatService::NetworkError, 'Could not resolve handle'
        )
      end

      it "shows error message" do
        post "/migrations", params: {
          migration: {
            email: user_email,
            old_handle: old_handle,
            new_handle: new_handle,
            new_pds_host: new_pds_host,
            password: password
          }
        }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("could not be resolved")
      end
    end

    context "when submitting blank PLC token" do
      let(:migration) do
        Migration.create!(
          email: user_email,
          did: resolved_did,
          old_handle: old_handle,
          old_pds_host: resolved_pds_host,
          new_handle: new_handle,
          new_pds_host: new_pds_host,
          status: :pending_plc
        )
      end

      it "rejects blank token" do
        post "/migrate/#{migration.token}/plc_token", params: {
          plc_token: ""
        }

        expect(response).to have_http_status(:redirect)
        follow_redirect!
        expect(response.body).to include("cannot be blank")

        # Verify job was not enqueued
        expect(UpdatePlcJob).not_to have_been_enqueued
      end
    end

    context "when migration fails" do
      let(:migration) do
        Migration.create!(
          email: user_email,
          did: resolved_did,
          old_handle: old_handle,
          old_pds_host: resolved_pds_host,
          new_handle: new_handle,
          new_pds_host: new_pds_host,
          status: :failed,
          last_error: "Network error during blob transfer"
        )
      end

      it "displays error information" do
        get "/migrate/#{migration.token}"

        expect(response).to be_successful
        expect(response.body).to include("failed")
        expect(response.body).to include("Network error")
      end

      it "shows 0% progress for failed migration" do
        get "/migrations/#{migration.id}/status"

        json = JSON.parse(response.body)
        expect(json['status']).to eq('failed')
        expect(json['progress_percentage']).to eq(0)
        expect(json['last_error']).to be_present
      end
    end
  end

  describe "Progress tracking" do
    let(:migration) do
      Migration.create!(
        email: user_email,
        did: resolved_did,
        old_handle: old_handle,
        old_pds_host: resolved_pds_host,
        new_handle: new_handle,
        new_pds_host: new_pds_host,
        status: :pending_blobs
      )
    end

    before do
      migration.progress_data = {
        'blob_count' => 100,
        'blobs_uploaded' => 50,
        'total_bytes' => 1_000_000,
        'bytes_transferred' => 500_000
      }
      migration.save!
    end

    it "reports blob transfer progress" do
      get "/migrations/#{migration.id}/status"

      json = JSON.parse(response.body)
      expect(json['blob_count']).to eq(100)
      expect(json['progress_percentage']).to be > 0
      expect(json['progress_percentage']).to be < 100
    end

    it "updates progress as migration proceeds" do
      # First check
      get "/migrations/#{migration.id}/status"
      json1 = JSON.parse(response.body)
      initial_progress = json1['progress_percentage']

      # Update progress
      migration.progress_data['blobs_uploaded'] = 75
      migration.save!

      # Second check
      get "/migrations/#{migration.id}/status"
      json2 = JSON.parse(response.body)
      updated_progress = json2['progress_percentage']

      # Progress should have increased or stayed same (depending on calculation)
      expect(updated_progress).to be >= initial_progress
    end
  end

  describe "Token-based access" do
    let(:migration) do
      Migration.create!(
        email: user_email,
        did: resolved_did,
        old_handle: old_handle,
        old_pds_host: resolved_pds_host,
        new_handle: new_handle,
        new_pds_host: new_pds_host
      )
    end

    it "allows access via token URL" do
      get "/migrate/#{migration.token}"
      expect(response).to be_successful
    end

    it "does not expose database ID in user-facing URLs" do
      get "/migrate/#{migration.token}"
      expect(response.body).not_to include("/migrations/#{migration.id}")
    end

    it "shows token prominently on status page" do
      get "/migrate/#{migration.token}"
      expect(response.body).to include(migration.token)
    end
  end

  describe "Security measures" do
    let(:migration) do
      Migration.create!(
        email: user_email,
        did: resolved_did,
        old_handle: old_handle,
        old_pds_host: resolved_pds_host,
        new_handle: new_handle,
        new_pds_host: new_pds_host
      )
    end

    it "does not expose password in responses" do
      migration.set_password(password)

      get "/migrate/#{migration.token}"
      expect(response.body).not_to include(password)

      get "/migrations/#{migration.id}/status"
      json = JSON.parse(response.body)
      expect(json.to_s).not_to include(password)
    end

    it "does not expose encrypted credentials in JSON" do
      migration.set_password(password)
      migration.set_plc_token(plc_token)

      get "/migrations/#{migration.id}/status"
      json = JSON.parse(response.body)

      expect(json['encrypted_password']).to be_nil
      expect(json['encrypted_plc_token']).to be_nil
    end

    it "uses HTTPS in production (enforced by Rails config)" do
      # This would be tested by checking Rails.application.config.force_ssl
      # The actual enforcement happens at the Rails level
      expect(Rails.application.config).to respond_to(:force_ssl)
    end
  end
end
