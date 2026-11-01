# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../../../app/services/decidim_app/bijeljina/milica/platform_support_contact"

module DecidimApp
  module Bijeljina
    module Milica
      class PlatformSupportContactTest < Minitest::Test
        Settings = Struct.new(:public_support_name, :public_support_email, :public_support_website, keyword_init: true)

        def values(**settings) = PlatformSupportContact.values(settings: Settings.new(**settings))

        def test_missing_settings_have_no_inherited_contact
          assert_empty values
        end

        def test_explicit_public_contact_is_preserved_without_translating_addresses
          data = values(public_support_name: " Autorska zajednica ", public_support_email: "support@example.invalid",
                        public_support_website: "https://community.example.invalid/support")
          assert_equal({ "name" => "Autorska zajednica", "email" => "support@example.invalid",
                         "website" => "https://community.example.invalid/support" }, data)
          assert_predicate data, :frozen?
        end

        def test_partial_valid_contact_does_not_require_an_invented_address_or_other_fields
          assert_equal({ "email" => "support@example.invalid" }, values(public_support_email: "support@example.invalid"))
          assert_equal({ "website" => "https://community.example.invalid" },
                       values(public_support_email: "not an email", public_support_website: "https://community.example.invalid"))
        end

        def test_invalid_or_header_injecting_email_is_not_exposed
          ["not-an-email", "reader@example.invalid\nBcc: other@example.invalid", "bad @example.invalid", 123,
           "a" * 255 + "@example.invalid"].each do |email|
            refute values(public_support_email: email).key?("email"), email.inspect
          end
        end

        def test_website_requires_https_standard_port_no_credentials_and_a_host
          ["http://community.example.invalid", "javascript:alert(1)", "https://reader:example@community.example.invalid",
           "https://community.example.invalid:8443", "https:///support", "not a url"].each do |website|
            refute values(public_support_website: website).key?("website"), website
          end
        end

        def test_invalid_encoding_control_characters_and_unbounded_copy_are_rejected
          ["a" * 201, "unsafe\nname", "unsafe\tname", "\xFF".dup.force_encoding("UTF-8"), "\xFF".b].each do |name|
            refute values(public_support_name: name).key?("name")
          end
          refute values(public_support_website: "https://community.example.invalid/" + "a" * 2_000).key?("website")
        end

        def test_each_read_observes_current_configuration_instead_of_old_operator_data
          settings = Settings.new(public_support_email: "first@example.invalid")
          assert_equal "first@example.invalid", PlatformSupportContact.values(settings:).fetch("email")
          settings.public_support_email = "second@example.invalid"
          assert_equal "second@example.invalid", PlatformSupportContact.values(settings:).fetch("email")
          settings.public_support_email = nil
          refute PlatformSupportContact.values(settings:).key?("email")
        end

        def test_only_three_explicit_public_settings_are_read
          settings = Object.new
          def settings.public_support_name = "Autorski operater"
          def settings.public_support_email = "support@example.invalid"
          def settings.public_support_website = nil
          def settings.method_missing(*) = raise("Unexpected private setting access")
          assert_equal %w(email name), PlatformSupportContact.values(settings:).keys.sort
        end
      end
    end
  end
end
