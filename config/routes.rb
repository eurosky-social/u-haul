# require 'sidekiq/web'

Rails.application.routes.draw do
  # Mount Sidekiq Web UI with Basic Auth
  # Sidekiq::Web.use Rack::Auth::Basic do |username, password|
  #   ActiveSupport::SecurityUtils.secure_compare(
  #     ::Digest::SHA256.hexdigest(username),
  #     ::Digest::SHA256.hexdigest(ENV.fetch('SIDEKIQ_USERNAME', 'admin'))
  #   ) & ActiveSupport::SecurityUtils.secure_compare(
  #     ::Digest::SHA256.hexdigest(password),
  #     ::Digest::SHA256.hexdigest(ENV.fetch('SIDEKIQ_PASSWORD', ''))
  #   )
  # end
  # mount Sidekiq::Web => '/sidekiq'

  # Root route
  root "migrations#new"

  # Health check endpoints
  get "/_health", to: "health#index"
  get "up" => "rails/health#show", as: :rails_health_check

  # Legal pages (served as ERB templates with ENV values)
  get "/privacy-policy", to: "legal#privacy_policy", as: :privacy_policy
  get "/terms-of-service", to: "legal#terms_of_service", as: :terms_of_service

  # Migrations resource routes
  resources :migrations, only: [:new, :create, :show] do
    collection do
      get :search_actors
      post :lookup_handle
      post :check_pds
      post :check_handle
      post :check_did_on_pds
      post :verify_target_credentials
    end
    member do
      post :submit_plc_token
      post :request_new_plc_token
      post :resend_verification
      get :status
      get :download_backup
      post :retry
      get :export_recovery_data
      post :retry_failed_blobs
    end
  end

  # Token-based access routes (no authentication required)
  get "/migrate/:token", to: "migrations#show", as: :migration_by_token
  post "/migrate/:token/verify", to: "migrations#verify_email", as: :verify_email
  post "/migrate/:token/resend_verification", to: "migrations#resend_verification", as: :resend_verification_by_token
  post "/migrate/:token/plc_token", to: "migrations#submit_plc_token", as: :submit_plc_token_by_token
  post "/migrate/:token/request_new_plc_token", to: "migrations#request_new_plc_token", as: :request_new_plc_token_by_token
  get "/migrate/:token/download", to: "migrations#download_backup", as: :migration_download_backup
  post "/migrate/:token/retry", to: "migrations#retry", as: :retry_migration_by_token
  get "/migrate/:token/export_recovery_data", to: "migrations#export_recovery_data", as: :export_recovery_data_migration_by_token
  post "/migrate/:token/retry_failed_blobs", to: "migrations#retry_failed_blobs", as: :retry_failed_blobs_by_token
  post "/migrate/:token/reauthenticate", to: "migrations#reauthenticate", as: :reauthenticate_by_token
  post "/migrate/:token/reauthenticate_new_pds", to: "migrations#reauthenticate_new_pds", as: :reauthenticate_new_pds_by_token
  post "/migrate/:token/request_cancellation", to: "migrations#request_cancellation", as: :request_cancellation_by_token
  get "/migrate/:token/confirm_cancellation", to: "migrations#confirm_cancellation", as: :confirm_cancellation_by_token
  post "/migrate/:token/confirm_delete", to: "migrations#confirm_delete", as: :confirm_delete_by_token
end
