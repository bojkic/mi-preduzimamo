# frozen_string_literal: true

require "test_helper"

class PublicNeighborhoodActivityTest < ActiveSupport::TestCase
  Reader = DecidimApp::Bijeljina::Milica::PublicNeighborhoodActivity
  Area = Data.define(:slug, :kind, :decidim_organization_id, :boundary)

  test "newer removed reports cannot crowd out visible facts or expose their removal reason" do
    organization = create_organization
    now = Time.current
    visible = Decidim::Bih::Report.create!(organization:, description: "PRIVATE VISIBLE DESCRIPTION",
                                           latitude: 44.75, longitude: 19.25, created_at: now - 1.day)
    hidden = 4.times.map do |index|
      Decidim::Bih::Report.create!(organization:, description: "PRIVATE REMOVED DESCRIPTION",
                                   latitude: 44.75, longitude: 19.25, created_at: now - (index + 1).hours,
                                   removed_from_public_at: now, removed_from_public_reason: "privacy")
    end
    area = Area.new("synthetic-neighborhood", "komsiluk", organization.id,
                    { "type" => "Polygon", "coordinates" => [[[19, 44], [20, 44], [20, 45], [19, 45], [19, 44]]] })

    result = Reader.new(organization:).call(areas: [area], now:, starts_at: now - 7.days,
                                            ends_at: now, explicit_time: true, locale: :sr)

    assert_equal "ok", result.status
    assert_equal([visible.reference], result.facts.map { |fact| fact.fetch("reference") })
    assert_equal false, result.coverage.fetch("truncated")
    hidden.each { |report| assert_not_includes result.to_json, report.reference }
    assert_not_includes result.to_json, "PRIVATE REMOVED DESCRIPTION"
    assert_not_includes result.to_json, "privacy"
    assert_not_includes result.to_json, visible.description
  end
end
