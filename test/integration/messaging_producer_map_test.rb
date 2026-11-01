# frozen_string_literal: true

require "test_helper"

# Drift guard for the public registry-derived documentation; no private audit.
class MessagingProducerMapTest < ActiveSupport::TestCase
  MAP_PATH = Rails.root.join("docs/PORUKE.md")

  setup do
    @map = MAP_PATH.read
  end

  test "the public producer map exists at its documented path" do
    assert_predicate MAP_PATH, :exist?
  end

  test "every registered producer appears in the map" do
    missing = Decidim::Bih::Messaging::MessageClass.all.keys.reject { |key| @map.include?("`#{key}`") }

    assert_empty missing, "producer map is stale; regenerate it for: #{missing.join(", ")}"
  end

  test "the map does not list producers the registry does not have" do
    boundaries = Decidim::Bih::Messaging::MessageClass::EXTERNAL_BOUNDARIES.map { |boundary| boundary.fetch(:key) }
    listed = @map.scan(/^\| `([a-z0-9_]+\.[a-z0-9_]+)`/).flatten.uniq - boundaries
    unknown = listed.reject { |key| Decidim::Bih::Messaging::MessageClass.known?(key) }

    assert_empty unknown, "producer map lists classes the registry does not define: #{unknown.join(", ")}"
  end

  test "the map reports the same enrolled/legacy split as the registry" do
    registry = Decidim::Bih::Messaging::MessageClass

    assert_includes @map,
                    "Brojevi: #{registry.all.size} izvora poruka — #{registry.enrolled.size} shadow, " \
                    "#{registry.legacy_unmigrated.size} legacy/unmigrated."
  end

  test "every named non-producer boundary is documented and is not a producer" do
    Decidim::Bih::Messaging::MessageClass::EXTERNAL_BOUNDARIES.each do |boundary|
      assert_includes @map, "`#{boundary.fetch(:key)}`"
      assert_not Decidim::Bih::Messaging::MessageClass.known?(boundary.fetch(:key))
    end
  end

  test "public map content matches all current registry fields without writing" do
    load Rails.root.join("script/message_producer_map").to_s
    assert_equal PublicMessageProducerMap.render, @map
  end

  test "phase 1 enrolment stays shadow-only and a strict minority" do
    registry = Decidim::Bih::Messaging::MessageClass

    registry.enrolled.each_value { |entry| assert_equal "shadow", entry.enrollment }
    assert_operator registry.enrolled.size, :<, registry.legacy_unmigrated.size
  end
end
