# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../../../../app/services/decidim_app/bijeljina/legal_pages_configuration"
require_relative "../../../support/synthetic_legal_pages"

class OpenSourceLegalConfigurationTest < Minitest::Test
  Config = DecidimApp::Bijeljina::LegalPagesConfiguration

  def test_explicit_authored_configuration_preserves_all_pages_and_does_not_mutate_input
    input = SyntheticLegalPages.configuration
    result = Config.load(input)
    assert_equal Config::REQUIRED_SLUGS.sort, result.fetch(:pages).keys.sort
    assert_equal "2040-02-03", result.dig(:pages, "privacy-policy", :updated_on)
    result[:pages].clear
    assert_equal 4, input.fetch("pages").size
  end

  def test_missing_configuration_does_not_inherit_local_copy
    old = ENV.delete("MI_LEGAL_PAGES_PATH")
    assert_raises(Config::Invalid) { Config.load }
  ensure
    old.nil? ? ENV.delete("MI_LEGAL_PAGES_PATH") : ENV["MI_LEGAL_PAGES_PATH"] = old
  end

  def test_explicit_file_is_loaded_and_invalid_file_is_rejected
    Dir.mktmpdir("synthetic-legal-") do |dir|
      path = File.join(dir, "legal.json")
      File.write(path, JSON.generate(SyntheticLegalPages.configuration))
      old = ENV["MI_LEGAL_PAGES_PATH"]
      ENV["MI_LEGAL_PAGES_PATH"] = path
      assert_equal 4, Config.load.fetch(:pages).size
      File.write(path, "not json")
      assert_raises(Config::Invalid) { Config.load }
    ensure
      old.nil? ? ENV.delete("MI_LEGAL_PAGES_PATH") : ENV["MI_LEGAL_PAGES_PATH"] = old
    end
  end

  def test_all_pages_and_valid_dates_are_required
    missing = SyntheticLegalPages.configuration
    missing.fetch("pages").delete("privacy-policy")
    assert_raises(Config::Invalid) { Config.load(missing) }
    invalid = SyntheticLegalPages.configuration
    invalid.fetch("pages").fetch("privacy-policy")["updated_on"] = "not a date"
    assert_raises(Config::Invalid) { Config.load(invalid) }
  end

  def test_contact_injection_and_non_string_paragraphs_are_rejected
    %w(contact_email contact_domain).each do |field|
      input = SyntheticLegalPages.configuration
      input[field] = '"><script>bad()</script>'
      assert_raises(Config::Invalid) { Config.load(input) }
    end
    input = SyntheticLegalPages.configuration
    input.fetch("pages").fetch("privacy-policy").fetch("sections").first.last << { "unexpected" => "object" }
    assert_raises(Config::Invalid) { Config.load(input) }
  end

  def test_invalid_container_slug_and_weight_are_rejected
    assert_raises(Config::Invalid) { Config.load([]) }
    input = SyntheticLegalPages.configuration
    input.fetch("pages")["../escape"] = input.fetch("pages").fetch("privacy-policy")
    assert_raises(Config::Invalid) { Config.load(input) }
    input = SyntheticLegalPages.configuration
    input.fetch("pages").fetch("privacy-policy")["weight"] = -1
    assert_raises(Config::Invalid) { Config.load(input) }
  end
end
