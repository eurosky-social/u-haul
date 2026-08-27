# frozen_string_literal: true

require 'rails_helper'

# The endpoint this replaced returned a hardcoded {"status":"ok"} and so
# reported the service healthy through five straight days of total DNS failure
# in August 2026, while every handle lookup was failing. These specs exist to
# keep it capable of saying "no".
RSpec.describe 'Health check', type: :request do
  let(:resolver) { instance_double(Resolv::DNS, close: nil) }

  before do
    allow(Resolv::DNS).to receive(:new).and_return(resolver)
    allow(resolver).to receive(:timeouts=)
    allow(resolver).to receive(:getaddress).and_return(Resolv::IPv4.create('1.2.3.4'))
  end

  context 'when every dependency answers' do
    it 'returns 200 and reports each check' do
      get '/_health'

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json['status']).to eq('ok')
      expect(json.dig('checks', 'database', 'ok')).to be(true)
      expect(json.dig('checks', 'dns', 'ok')).to be(true)
    end
  end

  context 'when name resolution is dead' do
    before do
      allow(resolver).to receive(:getaddress).and_raise(Resolv::ResolvError, 'no resolver')
    end

    it 'returns 503 so monitoring notices' do
      get '/_health'

      expect(response).to have_http_status(:service_unavailable)
      expect(JSON.parse(response.body)['status']).to eq('degraded')
    end

    it 'names the failing check without leaking the error message' do
      get '/_health'

      dns = JSON.parse(response.body).dig('checks', 'dns')
      expect(dns['ok']).to be(false)
      expect(dns['error']).to eq('Resolv::ResolvError')
      # This endpoint is unauthenticated; exception messages can carry internal
      # hostnames and connection strings.
      expect(response.body).not_to include('no resolver')
    end
  end

  context 'when the database is unreachable' do
    before do
      allow(ActiveRecord::Base.connection)
        .to receive(:select_value).and_raise(ActiveRecord::StatementInvalid, 'down')
    end

    it 'returns 503' do
      get '/_health'

      expect(response).to have_http_status(:service_unavailable)
      expect(JSON.parse(response.body).dig('checks', 'database', 'ok')).to be(false)
    end
  end
end
