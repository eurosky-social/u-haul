Rails.application.routes.draw do
  # Root route
  root "migrations#new"

  # Health check endpoints
  get "/_health", to: "health#index"
  get "up" => "rails/health#show", as: :rails_health_check

  # Migrations resource routes
  resources :migrations, only: [:new, :create, :show] do
    member do
      post :submit_plc_token
      get :status
    end
  end

  # Token-based access routes (no authentication required)
  get "/migrate/:token", to: "migrations#show", as: :migration_by_token
  post "/migrate/:token/plc_token", to: "migrations#submit_plc_token", as: :submit_plc_token_by_token
end
