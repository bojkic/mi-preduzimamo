# frozen_string_literal: true

require "shakapacker"

# Decidim layouts emit Shakapacker pack tags, but the Minitest environment does
# not compile webpack assets. Tests that render those layouts use placeholder
# paths so browser/request coverage can focus on Rails behavior and public UI.
module ShakapackerManifestTestStub
  def lookup(name, pack_type = {})
    return super if compiled_test_assets?

    "/packs-test/#{name}"
  end

  def lookup!(name, pack_type = {})
    return super if compiled_test_assets?

    lookup(name, pack_type)
  end

  def lookup_pack_with_chunks(name, pack_type = {})
    return super if compiled_test_assets?

    ["/packs-test/#{name}"]
  end

  def lookup_pack_with_chunks!(name, pack_type = {})
    return super if compiled_test_assets?

    lookup_pack_with_chunks(name, pack_type)
  end

  private

  def compiled_test_assets?
    ENV["DECIDIM_TEST_COMPILED_ASSETS"] == "1"
  end
end

# Decidim pack helpers may create additional manifest instances. Apply the
# same fallback to each instance, while preserving compiled-asset browser tests.
Shakapacker::Manifest.prepend(ShakapackerManifestTestStub) unless Shakapacker::Manifest < ShakapackerManifestTestStub
