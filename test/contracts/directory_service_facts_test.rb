# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/deep_dup"
require_relative "../../app/services/decidim_app/bijeljina/directory_service_facts"
require File.join(Gem.loaded_specs.fetch("decidim-bih").full_gem_path, "app/services/decidim/bih/text")

require_relative "../support/synthetic_directory_facts"

class DirectoryServiceFactsTest < Minitest::Test
  include SyntheticDirectoryFacts

  def setup
    install_synthetic_directory_facts
  end

  def teardown
    restore_synthetic_directory_facts
  end
  Facts = DecidimApp::Bijeljina::DirectoryServiceFacts

  def test_hours_keep_the_provider_citation_separate_from_the_city_contact_page
    rows = selected(:socijalna_zastita, "Koji je telefon i radno vrijeme Centra?")
    assert_equal(%w(phone hours), rows.map { |row| row[:predicate] })
    assert_equal "https://provider.example.invalid/social/hours", rows.last[:source_url]
    assert_includes rows.first[:source_url], "/social/contact"
    assert(rows.all? { |row| row[:source_published_at].nil? })
  end

  def test_legalization_and_building_permit_offices_are_not_merged
    rows = selected(:gradjevinske_dozvole_legalizacija, "Telefon za legalizaciju")
    assert_equal 1, rows.size
    assert_equal "authored:legalization", rows.first[:subject_id]
    assert_includes rows.first[:text], "IZMIŠLJENI LEGALIZATION PHONE"
    assert_includes rows.first[:source_url], "/legalization/phone"
  end

  def test_family_medicine_phone_is_not_replaced_by_the_switchboard
    rows = selected(:zdravstvo_apoteke, "Телефон породичне медицине")
    assert_equal 1, rows.size
    assert_includes rows.first[:text], "IZMIŠLJENI FAMILY PHONE"
  end

  def test_pharmacy_rota_and_missing_hours_do_not_become_contact_answers
    assert_empty selected(:zdravstvo_apoteke, "Telefon dežurne apoteke")
    assert_empty selected(:zdravstvo_apoteke, "Telefon i radno vrijeme doma zdravlja")
  end

  def test_operator_override_cannot_inherit_shipped_atomic_claims
    assert_empty Facts.select(entry: { key: :socijalna_zastita, content_origin: "admin_override" }, query: "telefon", now: Time.utc(2026, 9, 15))
  end

  def test_every_requested_office_must_supply_every_requested_facet
    assert_empty selected(:gradjevinske_dozvole_legalizacija, "Adresa i telefon građevinskih dozvola i legalizacije")
    assert_empty selected(:socijalna_zastita, "Koji je kontakt i email Centra?")
    assert_empty selected(:zdravstvo_apoteke, "Telefon stomatologije doma zdravlja")
  end

  def test_future_reviews_and_withdrawn_facts_are_withheld
    row = Facts.all(:socijalna_zastita).first
    assert_empty Facts.eligible([row], now: Time.utc(2026, 9, 14))
    assert_empty Facts.eligible([row.merge(review_state: "withdrawn")], now: Time.utc(2026, 9, 15))
    assert_empty Facts.eligible([row.merge(effective_until: "2026-09-14")], now: Time.utc(2026, 9, 15))
    assert_empty Facts.eligible([row.merge(effective_from: "2026-10-01")], now: Time.utc(2026, 9, 15))
    assert_equal [row], Facts.eligible([row], now: Time.utc(2026, 9, 14, 22, 30))
  end

  private

  def selected(key, query)
    Facts.select(entry: { key: }, query:, now: Time.utc(2026, 9, 15, 12))
  end
end
