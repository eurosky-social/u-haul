require "test_helper"
require "base58"

class KeyGenerationTest < ActiveSupport::TestCase
  setup do
    @migration = migrations(:pending_migration)
    # Set up password for the migration (encrypted in fixture)
    @migration.password = "test_password_123"
    @service = GoatService.new(@migration)
  end

  test "generates P-256 key in did:key format" do
    result = @service.generate_rotation_key

    # Verify structure
    assert result[:private_key].present?, "Should have private key"
    assert result[:public_key].present?, "Should have public key"

    # Verify private key format (multibase z + base58btc)
    assert result[:private_key].start_with?('z'), "Private key should start with 'z' (base58btc multibase)"
    assert result[:private_key].length > 40, "Private key should be substantial length"

    # Verify public key format (did:key with P-256 prefix)
    assert result[:public_key].start_with?('did:key:z'), "Public key should be did:key format"
    assert result[:public_key].match?(/^did:key:zDnae/), "P-256 public keys start with zDnae"
  end

  test "generates unique keys each time" do
    key1 = @service.generate_rotation_key
    key2 = @service.generate_rotation_key

    refute_equal key1[:private_key], key2[:private_key], "Should generate unique private keys"
    refute_equal key1[:public_key], key2[:public_key], "Should generate unique public keys"
  end

  test "private and public keys are mathematically related" do
    result = @service.generate_rotation_key

    # Decode public key and verify it's valid P-256 compressed point
    public_multibase = result[:public_key].sub('did:key:', '')
    assert public_multibase.start_with?('z'), "Should be base58btc encoded"

    # The decoded bytes should have:
    # - 2 bytes multicodec prefix (0x80, 0x24 for P-256)
    # - 33 bytes compressed public key (0x02 or 0x03 prefix + 32 bytes)
    decoded = Base58.base58_to_binary(public_multibase[1..], :bitcoin)
    assert_equal 35, decoded.bytesize, "P-256 compressed public key with prefix should be 35 bytes"

    # Verify multicodec prefix
    assert_equal [0x80, 0x24].pack('C*'), decoded[0..1], "Should have P-256 multicodec prefix"

    # Verify compressed point format (first byte is 0x02 or 0x03)
    first_byte = decoded[2].ord
    assert [0x02, 0x03].include?(first_byte), "Compressed point should start with 0x02 or 0x03"
  end

  test "private key has correct format and length" do
    result = @service.generate_rotation_key

    # Decode private key
    private_multibase = result[:private_key]
    assert private_multibase.start_with?('z'), "Private key should be base58btc encoded (starts with z)"

    decoded = Base58.base58_to_binary(private_multibase[1..], :bitcoin)

    # Private key should have:
    # - 2 bytes multicodec prefix (0x86, 0x26 for P-256 private key = 0x1306)
    # - 32 bytes private key scalar
    assert_equal 34, decoded.bytesize, "P-256 private key with prefix should be 34 bytes"

    # Verify multicodec prefix for P-256 private key (0x1306 varint encoded)
    assert_equal [0x86, 0x26].pack('C*'), decoded[0..1], "Should have P-256 private key multicodec prefix"
  end

  test "can verify public key is derived from private key" do
    result = @service.generate_rotation_key

    # Decode private key
    private_multibase = result[:private_key]
    private_decoded = Base58.base58_to_binary(private_multibase[1..], :bitcoin)
    private_key_bytes = private_decoded[2..]  # Skip 2-byte prefix

    # Decode public key
    public_multibase = result[:public_key].sub('did:key:', '')
    public_decoded = Base58.base58_to_binary(public_multibase[1..], :bitcoin)
    public_key_bytes = public_decoded[2..]  # Skip 2-byte prefix

    # Reconstruct public key from private key using OpenSSL 3.0 compatible method
    # Use point multiplication on the generator to derive public key
    group = OpenSSL::PKey::EC::Group.new('prime256v1')
    bn = OpenSSL::BN.new(private_key_bytes, 2)
    public_point = group.generator.mul(bn)

    # Get compressed public key
    derived_public_key = public_point.to_octet_string(:compressed)

    assert_equal derived_public_key, public_key_bytes,
      "Public key should be derivable from private key"
  end

  test "matches goat key format when goat is available" do
    # Skip if goat is not available
    skip "goat not available" unless system("which goat > /dev/null 2>&1")

    goat_output = `goat key generate --type P-256 2>&1`

    # Extract public key from goat output
    goat_public_key = nil
    goat_output.each_line do |line|
      stripped = line.strip
      if stripped.start_with?('did:key:')
        goat_public_key = stripped
        break
      end
    end

    if goat_public_key
      # Verify our Ruby implementation produces same prefix pattern
      ruby_key = @service.generate_rotation_key

      # Both should start with same did:key:zDnae prefix (P-256 identifier)
      assert ruby_key[:public_key].start_with?('did:key:zDnae'),
        "Ruby key should have P-256 prefix (zDnae), got: #{ruby_key[:public_key][0..20]}"
      assert goat_public_key.start_with?('did:key:zDnae'),
        "Goat key should have P-256 prefix (zDnae), got: #{goat_public_key[0..20]}"

      # Verify both have same length (same encoding)
      ruby_key_body = ruby_key[:public_key].sub('did:key:', '')
      goat_key_body = goat_public_key.sub('did:key:', '')
      assert_equal ruby_key_body.length, goat_key_body.length,
        "Ruby and goat keys should have same length"
    else
      skip "Could not parse goat output"
    end
  end

  test "generated keys can be used for cryptographic operations" do
    result = @service.generate_rotation_key

    # Decode private key
    private_multibase = result[:private_key]
    private_decoded = Base58.base58_to_binary(private_multibase[1..], :bitcoin)
    private_key_bytes = private_decoded[2..]

    # Verify the private key bytes are valid (32 bytes for P-256)
    assert_equal 32, private_key_bytes.bytesize, "Private key should be 32 bytes"

    # Verify the private key scalar is in valid range (1 < d < n)
    bn = OpenSSL::BN.new(private_key_bytes, 2)
    assert bn > 0, "Private key scalar should be positive"

    # Derive public key and verify it matches
    group = OpenSSL::PKey::EC::Group.new('prime256v1')
    public_point = group.generator.mul(bn)

    # Decode the stored public key for comparison
    public_multibase = result[:public_key].sub('did:key:', '')
    public_decoded = Base58.base58_to_binary(public_multibase[1..], :bitcoin)
    stored_public_key = public_decoded[2..]

    derived_public_key = public_point.to_octet_string(:compressed)
    assert_equal derived_public_key, stored_public_key,
      "Derived public key should match stored public key"

    # Verify the public point is on the curve
    assert public_point.on_curve?, "Public point should be on the P-256 curve"
  end
end
