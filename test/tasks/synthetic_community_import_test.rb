# frozen_string_literal: true
require "test_helper"
require "rake"

class SyntheticCommunityImportTest < ActiveSupport::TestCase
  setup do
    @organization = create_organization
    Rails.application.load_tasks unless Rake::Task.task_defined?("decidim_bih:geo:import_areas")
    @task = Rake::Task["decidim_bih:geo:import_areas"]
  end

  test "synthetic example imports idempotently and resolves fictional geography" do
    path = Rails.root.join("db/examples/synthetic_community.geojson").to_s
    scope = Decidim::Bih::LocalArea.where(decidim_organization_id: @organization.id)
    capture_io do
      assert_difference -> { scope.count }, 5 do
        @task.reenable
        @task.invoke(path, @organization.host)
      end
      assert_no_difference -> { scope.count } do
        @task.reenable
        @task.invoke(path, @organization.host)
      end
    end
    assert_equal 1, scope.mz.count
    assert_equal 4, scope.komsiluci.count
    resolved = Decidim::Bih::Geo::AreaLocator.new.resolve(lat: 0.005, lon: 0.005, organization: @organization)
    assert_equal "primjer-mz", resolved.fetch(:mz).slug
    assert_equal "primjer-komsiluk-1", resolved.fetch(:komsiluk).slug
    outside = Decidim::Bih::Geo::AreaLocator.new.resolve(lat: 1, lon: 1, organization: @organization)
    assert_nil outside.fetch(:mz)
    assert_nil outside.fetch(:komsiluk)
  end
end
