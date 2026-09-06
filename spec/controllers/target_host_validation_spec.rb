# frozen_string_literal: true

require 'rails_helper'

# The destination host field is autofilled by browsers/password managers with a
# handle or email address; the controller must refuse such values instead of
# probing https://<handle>/ and telling the user their account does not exist.
RSpec.describe MigrationsController, type: :controller do
  describe '#target_host_error' do
    let(:describe_server) { 'https://user.example.com/xrpc/com.atproto.server.describeServer' }

    def error_for(host, handles: ['user.example.com'])
      controller.send(:target_host_error, host, handles)
    end

    it 'accepts a normal PDS host with or without scheme' do
      expect(error_for('https://eurosky.social')).to be_nil
      expect(error_for('pds.example.net')).to be_nil
      expect(error_for('https://pds.example.net:8443/')).to be_nil
    end

    it 'accepts a blank host (presence is validated by the model)' do
      expect(error_for('')).to be_nil
      expect(error_for(nil)).to be_nil
    end

    it 'rejects an email address' do
      expect(error_for('me@example.com')).to include('not a valid server address')
    end

    it 'rejects values that are not hostname-shaped' do
      expect(error_for('not a host')).to include('not a valid server address')
      expect(error_for('localhost')).to include('not a valid server address')
    end

    it 'rejects the handle when no PDS answers there' do
      stub_request(:get, describe_server).to_return(status: 404)

      expect(error_for('user.example.com')).to include('is your handle')
    end

    it 'accepts a handle-shaped value when a PDS actually answers there' do
      stub_request(:get, describe_server)
        .to_return(status: 200, body: { availableUserDomains: ['.example.com'] }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      expect(error_for('user.example.com')).to be_nil
    end
  end
end
