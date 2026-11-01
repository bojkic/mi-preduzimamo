# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "json"
require "yaml"
require "open3"
require "rbconfig"

# Load the public provider only in a fresh Ruby process. Requiring its overlay
# here would redefine the private application's module during Rails discovery.
class PublicDirectoryFactsTest < Minitest::Test
  REPO = File.expand_path("../..", __dir__)
  OVERLAY = File.join(REPO, "script/open_source/overlays/app")
  ROOT = File.directory?(OVERLAY) ? OVERLAY : REPO
  PROVIDER = File.join(ROOT, "app/services/decidim_app/bijeljina/directory_service_facts.rb")

  def row(**changes)
    { "id" => "synthetic-contact", "logical_id" => "synthetic-contact", "fact_revision" => "v1",
      "document_id" => "synthetic-document", "publisher_id" => "synthetic-publisher",
      "source_document_sha256" => "a" * 64, "subject_id" => "synthetic-office", "predicate" => "phone",
      "text" => "IZMIŠLJENI KONTAKT — ne pozivati.", "source_url" => "https://community.example.invalid/contact",
      "source_checked_on" => "2040-09-14", "review_state" => "reviewed", "source_locator" => "authored-fixture" }.merge(changes.transform_keys(&:to_s))
  end

  def probe(rows = nil, hosts: "community.example.invalid", expression: "provider.data")
    Dir.mktmpdir("synthetic-directory-") do |directory|
      path = File.join(directory, "facts.yml")
      File.write(path, YAML.dump("service" => rows)) unless rows.nil?
      code = <<~RUBY
        require "bundler/setup"
        require "json"
        require "active_support"
        require "active_support/time"
        require #{PROVIDER.inspect}
        provider = DecidimApp::Bijeljina::DirectoryServiceFacts
        begin
          puts JSON.generate(value: (#{expression}))
        rescue ArgumentError, KeyError => error
          puts JSON.generate(error: error.class.name, message: error.message)
        end
      RUBY
      output, errors, status = Open3.capture3({ "MI_DIRECTORY_FACTS_PATH" => path,
        "MI_DIRECTORY_FACTS_REVIEWED_HOSTS" => hosts }, RbConfig.ruby, "-e", code)
      assert status.success?, errors
      JSON.parse(output)
    end
  end

  def test_absent_optional_data_has_no_facts
    assert_equal({}, probe.fetch("value"))
    assert_equal [], probe(expression: 'provider.all(:unconfigured_service)').fetch("value")
  end

  def test_present_invalid_data_is_not_silently_accepted
    result = probe([{ "id" => "duplicated" }, { "id" => "duplicated" }])
    assert_equal "ArgumentError", result.fetch("error")
    assert_match "duplicate directory fact identity", result.fetch("message")
  end

  def test_explicit_reviewed_https_source_is_available
    result = probe([row])
    assert_equal [row], result.fetch("value").fetch("service")
    assert_equal true, probe([row], expression: 'provider.reviewed_source_url?("https://community.example.invalid/contact")').fetch("value")
  end

  def test_source_trust_requires_exact_host_https_no_credentials_and_default_port
    ["http://community.example.invalid/contact", "https://user:pass@community.example.invalid/contact",
     "https://other.example.invalid/contact", "https://sub.community.example.invalid/contact",
     "https://community.example.invalid:444/contact"].each do |url|
      assert_equal "unreviewed directory source", probe([row(source_url: url)]).fetch("message"), url
    end
    assert_equal "unreviewed directory source", probe([row], hosts: "").fetch("message")
    assert_equal [row], probe([row], hosts: " COMMUNITY.EXAMPLE.INVALID , ").fetch("value").fetch("service")
  end

  def test_invalid_source_date_is_rejected
    assert_equal "Date::Error", probe([row(source_checked_on: "not-a-date")]).fetch("error")
  end

  def test_eligibility_excludes_unreviewed_future_and_expired_facts
    expression = 'provider.eligible(provider.all(:service), now: Time.utc(2040, 9, 16, 12)).map { |r| r.fetch(:id) }'
    assert_equal ["synthetic-contact"], probe([row], expression: expression).fetch("value")
    [row(review_state: "draft"), row(source_checked_on: "2040-09-17"),
     row(effective_from: "2040-09-17"), row(effective_until: "2040-09-15")].each do |fact|
      assert_equal [], probe([fact], expression: expression).fetch("value")
    end
    assert_equal ["synthetic-contact"], probe([row(effective_from: "2040-09-16", effective_until: "2040-09-16")], expression: expression).fetch("value")
  end
end
