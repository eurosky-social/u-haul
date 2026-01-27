# MigrationsController - User-facing controller for PDS migrations
#
# This controller provides both HTML views for users and JSON API endpoints
# for status polling. No authentication is required - access is controlled
# via the migration token in the URL.
#
# Actions:
#   - new: Display migration form
#   - create: Start a new migration, generate token, redirect to status page
#   - show: Display status page (HTML) or return JSON based on format
#   - submit_plc_token: Accept and store the PLC token, trigger UpdatePlcJob
#   - status: JSON API endpoint for real-time status polling
#
# Security:
#   - Token-based access only (no user authentication)
#   - Tokens are found via URL parameter, not database ID
#   - PLC tokens are encrypted before storage
#   - Credentials have expiration times
#
# Routes:
#   GET  /migrations/new
#   POST /migrations
#   GET  /migrations/:id
#   GET  /migrate/:token (alias for show)
#   POST /migrations/:id/submit_plc_token
#   POST /migrate/:token/plc_token (alias for submit_plc_token)
#   GET  /migrations/:id/status (JSON only)

class MigrationsController < ApplicationController
  before_action :set_migration, only: [:show, :submit_plc_token, :status]

  # GET /migrations/new
  # Display the migration form where users enter their account details
  def new
    @migration = Migration.new
  end

  # POST /migrations
  # Create a new migration and redirect to the status page
  #
  # Params:
  #   - migration[email]: User's email address
  #   - migration[old_handle]: Current handle (e.g., user.bsky.social)
  #   - migration[old_pds_host]: Current PDS host (e.g., bsky.network)
  #   - migration[new_handle]: New handle (e.g., user.example.com)
  #   - migration[new_pds_host]: New PDS host (e.g., pds.example.com)
  #   - password: Account password (stored encrypted, not mass-assigned)
  #
  # Response:
  #   - Success: Redirects to status page with token
  #   - Failure: Re-renders form with errors
  def create
    @migration = Migration.new(migration_params)

    # Store the encrypted password separately (not mass-assigned)
    @migration.set_password(params[:password]) if params[:password].present?

    if @migration.save
      # Migration saved successfully, token generated, CreateAccountJob scheduled
      redirect_to migration_by_token_path(@migration.token),
                  notice: "Migration started! Track your progress with token: #{@migration.token}"
    else
      render :new, status: :unprocessable_entity
    end
  end

  # GET /migrations/:id
  # GET /migrate/:token
  # Display migration status page (HTML) or return JSON based on format
  #
  # Supports both ID-based and token-based access via different routes.
  # The token-based route is preferred for user-facing URLs.
  #
  # Formats:
  #   - HTML: Renders status page with progress bar
  #   - JSON: Returns migration status data (same as status action)
  def show
    respond_to do |format|
      format.html
      format.json { render json: migration_status_json }
    end
  end

  # POST /migrations/:id/submit_plc_token
  # POST /migrate/:token/plc_token
  # Accept and store the PLC token from the user, then trigger UpdatePlcJob
  #
  # This endpoint is called when the user has obtained their PLC operation token
  # from their old PDS and submits it to complete the migration. This is the
  # critical "point of no return" step that will redirect their DID to the new PDS.
  #
  # Params:
  #   - plc_token: The PLC operation token from the old PDS
  #
  # Response:
  #   - Success: Redirects to status page with success message
  #   - Failure: Redirects to status page with error message
  def submit_plc_token
    plc_token = params[:plc_token]

    if plc_token.blank?
      redirect_to migration_by_token_path(@migration.token),
                  alert: "PLC token cannot be blank"
      return
    end

    # Store the encrypted PLC token with expiration
    @migration.set_plc_token(plc_token)

    # Trigger the critical UpdatePlcJob to update the PLC directory
    UpdatePlcJob.perform_later(@migration)

    redirect_to migration_by_token_path(@migration.token),
                notice: "PLC token submitted! Your DID will be updated shortly."
  rescue StandardError => e
    Rails.logger.error("Failed to submit PLC token for migration #{@migration.token}: #{e.message}")
    redirect_to migration_by_token_path(@migration.token),
                alert: "Failed to submit PLC token: #{e.message}"
  end

  # GET /migrations/:id/status
  # JSON API endpoint for real-time status polling
  #
  # This endpoint is designed for AJAX polling from the status page.
  # It returns the current migration status, progress percentage,
  # estimated time remaining, and any errors.
  #
  # Response format:
  #   {
  #     "token": "EURO-ABC12345",
  #     "status": "pending_blobs",
  #     "progress_percentage": 45,
  #     "estimated_time_remaining": 300,
  #     "blob_count": 100,
  #     "blobs_uploaded": 45,
  #     "total_bytes_transferred": 1234567,
  #     "last_error": null,
  #     "created_at": "2026-01-27T10:00:00Z",
  #     "updated_at": "2026-01-27T10:15:00Z"
  #   }
  def status
    render json: migration_status_json
  end

  private

  # Find migration by token (from URL parameter)
  # Handles both :id and :token parameters to support different routes
  #
  # Routes:
  #   - /migrations/:id/status uses params[:id]
  #   - /migrate/:token uses params[:token]
  def set_migration
    token = params[:token] || params[:id]
    @migration = Migration.find_by(token: token)

    unless @migration
      respond_to do |format|
        format.html do
          render plain: "Migration not found with token: #{token}",
                 status: :not_found
        end
        format.json do
          render json: { error: "Migration not found" },
                 status: :not_found
        end
      end
    end
  end

  # Strong parameters for migration creation
  # The password is handled separately and not mass-assigned
  def migration_params
    params.require(:migration).permit(
      :email,
      :old_handle,
      :old_pds_host,
      :new_handle,
      :new_pds_host,
      :did
    )
  end

  # Format migration data for JSON API response
  # Includes all relevant status information for client-side polling
  def migration_status_json
    blob_data = calculate_blob_statistics

    {
      token: @migration.token,
      status: @migration.status,
      progress_percentage: @migration.progress_percentage,
      estimated_time_remaining: @migration.estimated_time_remaining,
      blob_count: blob_data[:count],
      blobs_uploaded: blob_data[:uploaded],
      total_bytes_transferred: blob_data[:bytes_transferred],
      last_error: @migration.last_error,
      created_at: @migration.created_at.iso8601,
      updated_at: @migration.updated_at.iso8601
    }
  end

  # Calculate blob upload statistics from progress_data
  # Returns a hash with count, uploaded, and bytes_transferred
  def calculate_blob_statistics
    blobs = @migration.progress_data['blobs'] || {}

    {
      count: blobs.size,
      uploaded: blobs.values.count { |b| b['uploaded'] == b['size'] },
      bytes_transferred: blobs.values.sum { |b| b['uploaded'].to_i }
    }
  end
end
