# frozen_string_literal: true

require 'rails_helper'

# MigrationsController Spec - Modern Rails 7 Style
# This file tests the user-facing controller for PDS migrations.
# We use Migration.last instead of assigns(:migration) to maintain
# compatibility with Rails 7 without needing extra gems.
RSpec.describe MigrationsController, type: :controller do
  let(:valid_attributes) do
    {
      email: "test@example.com",
      old_handle: "test.bsky.social",
      new_handle: "test.example.com",
      new_pds_host: "https://pds.example.com",
      password: "test_password_123",
      legal_consent: "1",
      old_access_token: "mock_access_token",
      old_refresh_token: "mock_refresh_token"
    }
  end

  let(:resolved_did) { "did:plc:test123abc" }
  let(:resolved_pds_host) { "https://bsky.social" }

  before do
    # Mock the legal snapshots so the LegalConsent record can be created without DB setup
    # Schema columns: document_type, content_hash, rendered_content, version_label
    allow(LegalSnapshot).to receive(:current).with('terms_of_service').and_return(
      LegalSnapshot.new(document_type: 'terms_of_service', version_label: '1.0', content_hash: 'mock_tos_hash', rendered_content: '<p>TOS</p>')
    )
    allow(LegalSnapshot).to receive(:current).with('privacy_policy').and_return(
      LegalSnapshot.new(document_type: 'privacy_policy', version_label: '1.0', content_hash: 'mock_pp_hash', rendered_content: '<p>Privacy</p>')
    )
  end

  describe "GET #new" do
    it "returns a success response" do
      get :new
      expect(response).to be_successful
    end
  end

  describe "POST #create" do
    context "with valid params" do
      before do
        allow(GoatService).to receive(:resolve_handle).with(valid_attributes[:old_handle]).and_return(
          { did: resolved_did, pds_host: resolved_pds_host }
        )

        # SECURITY FIX: Simulate lookup_handle having stored the real email in the session
        session[:authenticated_pds_email] = valid_attributes[:email]
      end

      it "creates a new Migration" do
        expect {
          post :create, params: { migration: valid_attributes }
        }.to change(Migration, :count).by(1)
      end

      it "resolves old handle to DID and PDS host" do
        expect(GoatService).to receive(:resolve_handle).with(valid_attributes[:old_handle])
        post :create, params: { migration: valid_attributes }
      end

      it "sets DID from resolution" do
        post :create, params: { migration: valid_attributes }
        expect(Migration.last.did).to eq(resolved_did)
      end

      it "sets old PDS host from resolution" do
        post :create, params: { migration: valid_attributes }
        expect(Migration.last.old_pds_host).to eq(resolved_pds_host)
      end

      it "generates and encrypts a random password for the new account" do
        post :create, params: { migration: valid_attributes }
        expect(Migration.last.encrypted_password).to be_present
        # migration_out generates a random password, NOT the form-submitted one
        expect(Migration.last.password).to be_present
        expect(Migration.last.password).not_to eq(valid_attributes[:password])
      end

      it "sets credentials expiration to 48 hours" do
        freeze_time do
          post :create, params: { migration: valid_attributes }
          expect(Migration.last.credentials_expires_at).to be_within(1.second).of(48.hours.from_now)
        end
      end

      it "generates a migration token" do
        post :create, params: { migration: valid_attributes }
        expect(Migration.last.token).to match(/\AEURO-[A-Z0-9]{16}\z/)
      end

      it "redirects to migration status page by token" do
        post :create, params: { migration: valid_attributes }
        expect(response).to redirect_to(migration_by_token_path(Migration.last.token))
      end

      it "enqueues first job" do
        expect {
          post :create, params: { migration: valid_attributes }
        }.to have_enqueued_job
      end
    end

    context "with invalid params" do
      let(:invalid_attributes) do
        {
          email: "invalid_email",
          old_handle: "",
          new_handle: "",
          new_pds_host: ""
        }
      end

      before do
        session[:authenticated_pds_email] = "invalid_email"
      end

      it "does not create a new Migration" do
        expect {
          post :create, params: { migration: invalid_attributes }
        }.not_to change(Migration, :count)
      end

      it "returns unprocessable entity status" do
        post :create, params: { migration: invalid_attributes }
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    # ==========================================================================
    # Security: Stateless Validation Gap (Reproduction Case)
    # ==========================================================================
    context "when Cynthia attempts to tamper with the authenticated email" do
      before do
        # 1. CYNTHIA PERFORMS A VALID LOOKUP
        session[:authenticated_pds_email] = "real@cynthia.com"
        allow(GoatService).to receive(:resolve_handle).and_return(
          { did: resolved_did, pds_host: resolved_pds_host }
        )
      end

      it "rejects the migration if the submitted email does not match the session" do
        # 2. CYNTHIA TAMPERS WITH THE FORM
        post :create, params: { 
          migration: valid_attributes.merge(email: "hacker@evil.com") 
        }

        # 3. EXPECT REJECTION (Currently fails because the lock is missing!)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(Migration.last&.email).not_to eq("hacker@evil.com")
      end
    end

    context "when no session exists because lookup step was skipped" do
      before do
        allow(GoatService).to receive(:resolve_handle).and_return(
          { did: resolved_did, pds_host: resolved_pds_host }
        )
      end

      it "rejects the migration as an expired session" do
        post :create, params: { migration: valid_attributes }
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    context "when email matches but has different casing" do
      before do
        allow(GoatService).to receive(:resolve_handle).and_return(
          { did: resolved_did, pds_host: resolved_pds_host }
        )
        session[:authenticated_pds_email] = "CYNTHIA@Example.COM"
      end

      it "accepts the email as valid if it matches case-insensitively" do
        post :create, params: {
          migration: valid_attributes.merge(email: "cynthia@example.com")
        }
        expect(response).to be_redirect
      end
    end
  end

  describe "GET #show" do
    let(:migration) do
      Migration.create!(
        email: "test@example.com",
        did: "did:plc:test123",
        old_handle: "test.old.bsky.social",
        old_pds_host: "https://old.pds",
        new_handle: "test.new.bsky.social",
        new_pds_host: "https://new.pds",
        status: :pending_repo,
        password: "test"
      )
    end

    context "with HTML format" do
      it "returns a success response" do
        # FIX: Sebastian's code used migration.id, but the route requires migration.token
        get :show, params: { id: migration.token }
        expect(response).to be_successful
      end
    end

    context "with JSON format" do
      it "returns JSON response" do
        get :show, params: { id: migration.token }, format: :json
        expect(response.content_type).to include('application/json')
      end

      it "includes migration token" do
        get :show, params: { id: migration.token }, format: :json
        json = JSON.parse(response.body)
        expect(json['token']).to eq(migration.token)
      end

      it "includes migration status" do
        get :show, params: { id: migration.token }, format: :json
        json = JSON.parse(response.body)
        expect(json['status']).to eq('pending_repo')
      end
    end
  end

  describe "POST #submit_plc_token" do
    let(:migration) do
      Migration.create!(
        email: "test@example.com",
        did: "did:plc:test123",
        old_handle: "test.old.bsky.social",
        old_pds_host: "https://old.pds",
        new_handle: "test.new.bsky.social",
        new_pds_host: "https://new.pds",
        status: :pending_plc,
        password: "test",
        credentials_expires_at: 48.hours.from_now,
        old_access_token: "mock_old_access",
        old_refresh_token: "mock_old_refresh"
      )
    end

    let(:plc_token) { "plc_token_123abc" }

    context "with valid PLC token" do
      it "stores the encrypted PLC token" do
        post :submit_plc_token, params: { id: migration.token, plc_token: plc_token }
        migration.reload
        expect(migration.encrypted_plc_token).to be_present
        expect(migration.plc_token).to eq(plc_token)
      end

      it "enqueues UpdatePlcJob" do
        expect {
          post :submit_plc_token, params: { id: migration.token, plc_token: plc_token }
        }.to have_enqueued_job(UpdatePlcJob).with(migration.id)
      end

      it "redirects to migration status page" do
        post :submit_plc_token, params: { id: migration.token, plc_token: plc_token }
        expect(response).to redirect_to(migration_by_token_path(migration.token))
      end
    end

    context "with blank PLC token" do
      it "does not store anything" do
        post :submit_plc_token, params: { id: migration.token, plc_token: "" }
        migration.reload
        expect(migration.encrypted_plc_token).to be_nil
      end

      it "redirects with error alert" do
        post :submit_plc_token, params: { id: migration.token, plc_token: "" }
        expect(response).to redirect_to(migration_by_token_path(migration.token))
      end
    end
  end

  describe "GET #status" do
    let(:migration) do
      Migration.create!(
        email: "test@example.com",
        did: "did:plc:test123",
        old_handle: "test.old.bsky.social",
        old_pds_host: "https://old.pds",
        new_handle: "test.new.bsky.social",
        new_pds_host: "https://new.pds",
        status: :pending_blobs,
        password: "test"
      )
    end

    before do
      migration.progress_data = {
        'blobs_total' => 100,
        'blobs_completed' => 50,
        'bytes_transferred' => 1024
      }
      migration.save!
    end

    it "returns JSON response" do
      get :status, params: { id: migration.token }
      expect(response.content_type).to include('application/json')
    end

    it "returns current status" do
      get :status, params: { id: migration.token }
      json = JSON.parse(response.body)
      expect(json['status']).to eq('pending_blobs')
    end
  end

  describe "token-based access" do
    let(:migration) do
      Migration.create!(
        email: "test@example.com",
        did: "did:plc:test123",
        old_handle: "test.old.bsky.social",
        old_pds_host: "https://old.pds",
        new_handle: "test.new.bsky.social",
        new_pds_host: "https://new.pds",
        password: "test"
      )
    end

    it "allows access via token for show action" do
      get :show, params: { id: migration.token }
      expect(response).to be_successful
    end

    it "allows access via token for submit_plc_token action" do
      post :submit_plc_token, params: { id: migration.token, plc_token: "test_token" }
      expect(response).to be_redirect
    end
  end
end
