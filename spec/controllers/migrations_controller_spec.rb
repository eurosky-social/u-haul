# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MigrationsController, type: :controller do
  let(:valid_attributes) do
    {
      email: "test@example.com",
      old_handle: "test.bsky.social",
      new_handle: "test.example.com",
      new_pds_host: "https://pds.example.com",
      password: "test_password_123"
    }
  end

  let(:resolved_did) { "did:plc:test123abc" }
  let(:resolved_pds_host) { "https://bsky.social" }

  describe "GET #new" do
    it "returns a success response" do
      get :new
      expect(response).to be_successful
    end

    it "assigns a new migration as @migration" do
      get :new
      expect(assigns(:migration)).to be_a_new(Migration)
    end
  end

  describe "POST #create" do
    context "with valid params" do
      before do
        # Mock handle resolution
        allow(GoatService).to receive(:resolve_handle).with(valid_attributes[:old_handle]).and_return(
          { did: resolved_did, pds_host: resolved_pds_host }
        )
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

        migration = Migration.last
        expect(migration.did).to eq(resolved_did)
      end

      it "sets old PDS host from resolution" do
        post :create, params: { migration: valid_attributes }

        migration = Migration.last
        expect(migration.old_pds_host).to eq(resolved_pds_host)
      end

      it "encrypts and stores password" do
        post :create, params: { migration: valid_attributes }

        migration = Migration.last
        expect(migration.encrypted_password).to be_present
        expect(migration.password).to eq(valid_attributes[:password])
      end

      it "sets credentials expiration to 48 hours" do
        freeze_time do
          post :create, params: { migration: valid_attributes }

          migration = Migration.last
          expect(migration.credentials_expires_at).to be_within(1.second).of(48.hours.from_now)
        end
      end

      it "generates a migration token" do
        post :create, params: { migration: valid_attributes }

        migration = Migration.last
        expect(migration.token).to match(/\AEURO-[A-Z0-9]{8}\z/)
      end

      it "redirects to migration status page by token" do
        post :create, params: { migration: valid_attributes }

        migration = Migration.last
        expect(response).to redirect_to(migration_by_token_path(migration.token))
      end

      it "sets a success notice" do
        post :create, params: { migration: valid_attributes }

        expect(flash[:notice]).to include("Migration started")
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

      it "does not create a new Migration" do
        expect {
          post :create, params: { migration: invalid_attributes }
        }.not_to change(Migration, :count)
      end

      it "returns unprocessable entity status" do
        post :create, params: { migration: invalid_attributes }
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "renders the new template" do
        post :create, params: { migration: invalid_attributes }
        expect(response).to render_template(:new)
      end
    end

    context "when handle resolution fails" do
      before do
        allow(GoatService).to receive(:resolve_handle).and_raise(
          GoatService::NetworkError, 'Could not resolve handle'
        )
      end

      it "does not create a migration" do
        expect {
          post :create, params: { migration: valid_attributes }
        }.not_to change(Migration, :count)
      end

      it "adds error to old_handle field" do
        post :create, params: { migration: valid_attributes }

        expect(assigns(:migration).errors[:old_handle]).to be_present
        expect(assigns(:migration).errors[:old_handle]).to include(/could not be resolved/)
      end

      it "re-renders new template" do
        post :create, params: { migration: valid_attributes }
        expect(response).to render_template(:new)
      end

      it "logs the error" do
        expect(Rails.logger).to receive(:error).with(/Failed to resolve handle/)
        post :create, params: { migration: valid_attributes }
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
        status: :pending_repo
      )
    end

    context "with HTML format" do
      it "returns a success response" do
        get :show, params: { id: migration.id }
        expect(response).to be_successful
      end

      it "assigns the requested migration as @migration" do
        get :show, params: { id: migration.id }
        expect(assigns(:migration)).to eq(migration)
      end

      it "renders the show template" do
        get :show, params: { id: migration.id }
        expect(response).to render_template(:show)
      end
    end

    context "with JSON format" do
      it "returns JSON response" do
        get :show, params: { id: migration.id }, format: :json
        expect(response.content_type).to include('application/json')
      end

      it "includes migration token" do
        get :show, params: { id: migration.id }, format: :json

        json = JSON.parse(response.body)
        expect(json['token']).to eq(migration.token)
      end

      it "includes migration status" do
        get :show, params: { id: migration.id }, format: :json

        json = JSON.parse(response.body)
        expect(json['status']).to eq('pending_repo')
      end

      it "includes progress percentage" do
        get :show, params: { id: migration.id }, format: :json

        json = JSON.parse(response.body)
        expect(json['progress_percentage']).to be_present
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
        status: :pending_plc
      )
    end

    let(:plc_token) { "plc_token_123abc" }

    context "with valid PLC token" do
      it "stores the encrypted PLC token" do
        post :submit_plc_token, params: { id: migration.id, plc_token: plc_token }

        migration.reload
        expect(migration.encrypted_plc_token).to be_present
        expect(migration.plc_token).to eq(plc_token)
      end

      it "enqueues UpdatePlcJob" do
        expect {
          post :submit_plc_token, params: { id: migration.id, plc_token: plc_token }
        }.to have_enqueued_job(UpdatePlcJob).with(migration.id)
      end

      it "redirects to migration status page" do
        post :submit_plc_token, params: { id: migration.id, plc_token: plc_token }
        expect(response).to redirect_to(migration_by_token_path(migration.token))
      end

      it "sets a success notice" do
        post :submit_plc_token, params: { id: migration.id, plc_token: plc_token }
        expect(flash[:notice]).to include("PLC token submitted")
      end
    end

    context "with blank PLC token" do
      it "does not store anything" do
        post :submit_plc_token, params: { id: migration.id, plc_token: "" }

        migration.reload
        expect(migration.encrypted_plc_token).to be_nil
      end

      it "does not enqueue UpdatePlcJob" do
        expect {
          post :submit_plc_token, params: { id: migration.id, plc_token: "" }
        }.not_to have_enqueued_job(UpdatePlcJob)
      end

      it "redirects with error alert" do
        post :submit_plc_token, params: { id: migration.id, plc_token: "" }

        expect(response).to redirect_to(migration_by_token_path(migration.token))
        expect(flash[:alert]).to include("cannot be blank")
      end
    end

    context "when token storage fails" do
      before do
        allow_any_instance_of(Migration).to receive(:set_plc_token).and_raise(
          StandardError, 'Storage failed'
        )
      end

      it "redirects with error alert" do
        post :submit_plc_token, params: { id: migration.id, plc_token: plc_token }

        expect(response).to redirect_to(migration_by_token_path(migration.token))
        expect(flash[:alert]).to include("Failed to submit PLC token")
      end

      it "logs the error" do
        expect(Rails.logger).to receive(:error).with(/Failed to submit PLC token/)
        post :submit_plc_token, params: { id: migration.id, plc_token: plc_token }
      end

      it "does not enqueue UpdatePlcJob" do
        expect {
          post :submit_plc_token, params: { id: migration.id, plc_token: plc_token }
        }.not_to have_enqueued_job(UpdatePlcJob)
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
        status: :pending_blobs
      )
    end

    before do
      # Add some progress data
      migration.progress_data = {
        'blob_count' => 100,
        'blobs_uploaded' => 50
      }
      migration.save!
    end

    it "returns JSON response" do
      get :status, params: { id: migration.id }
      expect(response.content_type).to include('application/json')
    end

    it "returns migration token" do
      get :status, params: { id: migration.id }

      json = JSON.parse(response.body)
      expect(json['token']).to eq(migration.token)
    end

    it "returns current status" do
      get :status, params: { id: migration.id }

      json = JSON.parse(response.body)
      expect(json['status']).to eq('pending_blobs')
    end

    it "returns progress percentage" do
      get :status, params: { id: migration.id }

      json = JSON.parse(response.body)
      expect(json['progress_percentage']).to be_a(Integer)
      expect(json['progress_percentage']).to be >= 0
      expect(json['progress_percentage']).to be <= 100
    end

    it "returns blob count" do
      get :status, params: { id: migration.id }

      json = JSON.parse(response.body)
      expect(json['blob_count']).to eq(100)
    end

    it "returns timestamps" do
      get :status, params: { id: migration.id }

      json = JSON.parse(response.body)
      expect(json['created_at']).to be_present
      expect(json['updated_at']).to be_present
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
        new_pds_host: "https://new.pds"
      )
    end

    it "allows access via token for show action" do
      # This would test the token-based route: /migrate/:token
      # which should map to the show action
      # Note: The actual routing test should be in a request spec
      get :show, params: { id: migration.id }
      expect(response).to be_successful
    end

    it "allows access via token for submit_plc_token action" do
      # This would test the token-based route: /migrate/:token/plc_token
      post :submit_plc_token, params: { id: migration.id, plc_token: "test_token" }
      expect(response).to be_redirect
    end
  end

  describe "error handling" do
    it "handles missing migration gracefully" do
      expect {
        get :show, params: { id: 'nonexistent' }
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
