Rails.application.routes.draw do
  # Root route
  root "migrations#new"

  # Health check endpoints
  get "/_health", to: "health#index"
  get "up" => "rails/health#show", as: :rails_health_check

  # Migrations resource routes
  resources :migrations, only: [:new, :create, :show] do
    collection do
      post :lookup_handle
      post :check_pds
      post :check_handle
      post :check_did_on_pds
    end
    member do
      post :submit_plc_token
      post :request_new_plc_token
      get :status
      get :download_backup
      post :retry
      get :export_recovery_data
      post :retry_failed_blobs
    end
  end

  # Token-based access routes (no authentication required)
  get "/migrate/:token", to: "migrations#show", as: :migration_by_token
  get "/migrate/:token/verify/:verification_token", to: "migrations#verify_email", as: :verify_email
  post "/migrate/:token/plc_token", to: "migrations#submit_plc_token", as: :submit_plc_token_by_token
  post "/migrate/:token/request_new_plc_token", to: "migrations#request_new_plc_token", as: :request_new_plc_token_by_token
  get "/migrate/:token/download", to: "migrations#download_backup", as: :migration_download_backup
  post "/migrate/:token/retry", to: "migrations#retry", as: :retry_migration_by_token
  get "/migrate/:token/export_recovery_data", to: "migrations#export_recovery_data", as: :export_recovery_data_migration_by_token
  post "/migrate/:token/retry_failed_blobs", to: "migrations#retry_failed_blobs", as: :retry_failed_blobs_by_token
end
