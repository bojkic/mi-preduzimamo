# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Sistem48
      class DepartmentRoutingTest < ActiveSupport::TestCase
        setup do
          keys = ["SISTEM48_CENTRAL_INTAKE"] + Decidim::Bih::ReportTaxonomy::CATEGORIES.map { |category| DepartmentRouting.env_key(category) }
          @routing_env = keys.to_h { |key| [key, ENV[key]] }
          keys.each { |key| ENV.delete(key) }
          @routing_config = Decidim::Bih.sistem48_central_intake
          Decidim::Bih.sistem48_central_intake = "central@example.invalid"
        end

        teardown do
          Decidim::Bih.sistem48_central_intake = @routing_config
          @routing_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
        end

        test "defaults every category to the central Sistem 48 intake" do
          Decidim::Bih::ReportTaxonomy::CATEGORIES.each do |category|
            assert_equal DepartmentRouting.central_intake, DepartmentRouting.email_for(category)
          end
        end

        test "central intake is explicitly configured by the community" do
          assert_equal "central@example.invalid", DepartmentRouting.central_intake
        end

        test "a per-category ENV override redirects only that category" do
          key = DepartmentRouting.env_key(:putevi)
          original = ENV.fetch(key, nil)
          ENV[key] = "putevi@example.org"

          assert_equal "putevi@example.org", DepartmentRouting.email_for(:putevi)
          # Other categories still go to the central intake.
          assert_equal DepartmentRouting.central_intake, DepartmentRouting.email_for(:rasvjeta)
        ensure
          original.nil? ? ENV.delete(key) : ENV[key] = original
        end

        test "unclassified intake uses central routing and cannot infer a department" do
          organization = create_organization
          Setting.put(organization, "sistem48_routing", "central_intake", "central@example.org")
          Setting.put(organization, "sistem48_routing", "putevi", "roads@example.org")
          assert_equal "central@example.org", DepartmentRouting.email_for(nil, organization)
          Setting.put(organization, "sistem48_routing", "central_intake", nil)
          DepartmentRouting.stub(:central_intake_default, nil) do
            assert_nil DepartmentRouting.email_for(nil, organization)
          end
        end

        test "missing central configuration never supplies an inherited recipient" do
          Decidim::Bih.sistem48_central_intake = nil
          assert_nil DepartmentRouting.central_intake
          Decidim::Bih::ReportTaxonomy::CATEGORIES.each do |category|
            assert_nil DepartmentRouting.email_for(category)
          end
        end

        test "an explicit central environment recipient overrides host configuration" do
          ENV["SISTEM48_CENTRAL_INTAKE"] = "environment-intake@example.invalid"
          assert_equal "environment-intake@example.invalid", DepartmentRouting.central_intake
        end

        test "env_key builds the documented variable name" do
          assert_equal "SISTEM48_EMAIL_VODOVOD_KANALIZACIJA",
                       DepartmentRouting.env_key(:vodovod_kanalizacija)
        end
      end
    end
  end
end
