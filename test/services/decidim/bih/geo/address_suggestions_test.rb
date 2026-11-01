# frozen_string_literal: true

require "test_helper"

class AddressSuggestionsTest < ActiveSupport::TestCase
  setup do
    @organization = create_organization
    @area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-candidate", name: { "sr" => "Test komšiluk" },
                                            boundary: { "type" => "Polygon", "coordinates" => [[[19.21, 44.75], [19.22, 44.75], [19.22, 44.76], [19.21, 44.76], [19.21, 44.75]]] })
  end

  test "local candidates skip provider and still require an explicit choice" do
    geocoder = Object.new
    geocoder.define_singleton_method(:search) { |_| raise "local lookup must not contact provider" }
    lookup = ->(query:, organization:) { [{ label: query, komsiluk_id: @area.id, organization_id: organization.id }] }
    result = Decidim::Bih::Geo::AddressSuggestions.new(organization: @organization, geocoder:, local_lookup: lookup).call("Naselje")
    assert result.fetch(:found)
    assert result.fetch(:requires_selection)
    assert_equal "local", result.fetch(:source)
    assert_not result.has_key?(:komsiluk_id)
    assert_equal @area.id, result.fetch(:candidates).first.fetch(:komsiluk_id)
  end

  test "broad provider candidates focus the map while house candidates permit explicit selection" do
    geocoder = Object.new
    geocoder.define_singleton_method(:search) do |_query|
      %w(street place address).map { |precision| { label: "Public test", lat: 44.758, lon: 19.215, precision: } } +
        [{ label: "Outside", lat: 0, lon: 0, precision: "address" }]
    end
    result = Decidim::Bih::Geo::AddressSuggestions.new(organization: @organization, geocoder:, local_lookup: nil).call("Public test")
    assert_equal([true, true, false], result.fetch(:candidates).map { |row| row.fetch(:requires_map_confirmation) })
    assert_equal 3, result.fetch(:candidates).length
    assert_not result.has_key?(:lat)
    assert_not result.has_key?(:komsiluk_id)
  end
end
