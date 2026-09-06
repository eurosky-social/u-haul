# frozen_string_literal: true

require 'rails_helper'

# Covers GoatService's handle -> DID resolution: which strategies run, and the
# distinction between "the network answered and this handle does not exist"
# (HandleNotFoundError) and "we could not reach the network to ask"
# (NetworkError). Conflating those two is what made the 2026-08-21 DNS outage
# look, to every user, like they had mistyped their own handle.
RSpec.describe GoatService, type: :service do
  let(:handle) { 'alice.example.com' }
  let(:well_known_url) { "https://#{handle}/.well-known/atproto-did" }
  # Matched by regex: HTTParty appends ?handle=..., which a bare URL stub misses.
  let(:bsky_social) { %r{\Ahttps://bsky\.social/xrpc/com\.atproto\.identity\.resolveHandle} }
  let(:bsky_network) { %r{\Ahttps://bsky\.network/xrpc/com\.atproto\.identity\.resolveHandle} }

  # Resolv::DNS is not WebMock-able, so stand it in. Default: DNS answers, and
  # simply has no TXT record for this handle.
  let(:resolver) { instance_double(Resolv::DNS, close: nil) }

  before do
    allow(Resolv::DNS).to receive(:new).and_return(resolver)
    allow(resolver).to receive(:timeouts=)
    allow(resolver).to receive(:getresources).and_return([])
  end

  describe '.resolve_handle_to_did' do
    context 'when the handle publishes a well-known DID' do
      before do
        stub_request(:get, well_known_url).to_return(status: 200, body: 'did:plc:alice123')
      end

      # This strategy was documented in the method contract from the start but
      # never implemented, so a handle on any PDS other than bsky.social with no
      # DNS TXT record could only resolve if bsky.social happened to answer.
      it 'resolves via the well-known endpoint' do
        expect(described_class.resolve_handle_to_did(handle)).to eq('did:plc:alice123')
      end

      it 'does not fall through to the public PDS instances' do
        described_class.resolve_handle_to_did(handle)
        expect(a_request(:get, bsky_social)).not_to have_been_made
      end

      it 'ignores a body that is not a DID' do
        stub_request(:get, well_known_url).to_return(status: 200, body: '<html>nope</html>')
        stub_request(:get, bsky_social).to_return(status: 400, body: '{}')
        stub_request(:get, bsky_network).to_return(status: 400, body: '{}')

        expect { described_class.resolve_handle_to_did(handle) }
          .to raise_error(GoatService::HandleNotFoundError)
      end
    end

    context 'when every source answers and none knows the handle' do
      before do
        stub_request(:get, well_known_url).to_return(status: 404, body: '')
        stub_request(:get, bsky_social).to_return(status: 400, body: '{"error":"InvalidRequest"}')
        stub_request(:get, bsky_network).to_return(status: 400, body: '{"error":"InvalidRequest"}')
      end

      it 'raises HandleNotFoundError, not NetworkError' do
        expect { described_class.resolve_handle_to_did(handle) }
          .to raise_error(GoatService::HandleNotFoundError, /Could not resolve handle/)
      end
    end

    context 'when the network cannot be reached at all' do
      before do
        allow(resolver).to receive(:getresources).and_raise(Resolv::ResolvError, 'no resolver')
        stub_request(:get, well_known_url).to_timeout
        stub_request(:get, bsky_social).to_timeout
        stub_request(:get, bsky_network).to_timeout
      end

      # The whole point of the split: this must not tell the user their handle
      # is wrong.
      it 'raises NetworkError' do
        expect { described_class.resolve_handle_to_did(handle) }
          .to raise_error(GoatService::NetworkError, /unavailable/)
      end
    end

    context 'when only some sources are unreachable' do
      before do
        stub_request(:get, well_known_url).to_timeout
        stub_request(:get, bsky_social).to_return(
          status: 200, body: { did: 'did:plc:alice123' }.to_json
        )
      end

      it 'still resolves from the source that answered' do
        expect(described_class.resolve_handle_to_did(handle)).to eq('did:plc:alice123')
      end
    end
  end

  describe 'the resolution budget' do
    it 'caps a single attempt however much budget remains' do
      deadline = described_class.resolution_deadline(600)
      expect(described_class.attempt_timeout(deadline))
        .to eq(GoatService::HANDLE_RESOLUTION_ATTEMPT_TIMEOUT)
    end

    it 'reports no time left once the deadline has passed' do
      expect(described_class.attempt_timeout(described_class.resolution_deadline(-1))).to eq(0)
    end

    it 'skips a strategy that has no time left rather than starting it' do
      spent = described_class.resolution_deadline(-1)
      failures = []

      expect(described_class.resolve_did_via_well_known(handle, spent, failures)).to be_nil
      expect(a_request(:get, well_known_url)).not_to have_been_made
    end
  end
end
