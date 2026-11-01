# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Viber
      class InboundMessageTest < ActiveSupport::TestCase
        test "parse_all returns every result in a provider batch" do
          messages = InboundMessage.parse_all(
            "results" => [
              { "from" => "sender-1", "messageId" => "one", "message" => { "type" => "TEXT", "text" => "Prva" } },
              { "from" => "sender-2", "messageId" => "two", "message" => { "type" => "TEXT", "text" => "Druga" } }
            ]
          )

          assert_equal %w(one two), messages.map(&:message_id)
          assert_equal %w(Prva Druga), messages.map(&:text)
        end

        test "primitive envelope round trip preserves only required fields" do
          original = InboundMessage.parse(
            "results" => [{
              "from" => "sender-1",
              "messageId" => "one",
              "message" => {
                "type" => "LOCATION",
                "text" => "Problem",
                "location" => { "latitude" => 44.75, "longitude" => 19.21 }
              }
            }]
          )

          restored = InboundMessage.from_primitives(original.to_primitives)

          assert_equal original.sender, restored.sender
          assert_equal original.message_id, restored.message_id
          assert_equal original.text, restored.text
          assert_equal original.latitude, restored.latitude
          assert_equal original.longitude, restored.longitude
          assert_equal original.to_primitives.keys.sort,
                       %w(channel latitude longitude message_id sender text type)
        end
        test "parses a text message inside the results array" do
          message = InboundMessage.parse(
            "results" => [
              { "from" => "38765123456", "message" => { "type" => "TEXT", "text" => "Zdravo" } }
            ]
          )

          assert_equal "38765123456", message.sender
          assert_equal "Zdravo", message.text
          assert_equal "TEXT", message.type
          assert_nil message.image_url
          assert_nil message.latitude
          assert_nil message.longitude
          assert_not message.location?
        end

        test "parses an image message url" do
          message = InboundMessage.parse(
            "results" => [
              { "from" => "u1", "message" => { "type" => "IMAGE", "url" => "https://cdn/img/1.jpg" } }
            ]
          )

          assert_equal "https://cdn/img/1.jpg", message.image_url
          assert_nil message.text
          assert_equal "IMAGE", message.type
        end

        test "parses a nested location message" do
          message = InboundMessage.parse(
            "results" => [
              {
                "from" => "u2",
                "message" => {
                  "type" => "LOCATION",
                  "location" => { "latitude" => 44.7569, "longitude" => 19.2143 }
                }
              }
            ]
          )

          assert_in_delta 44.7569, message.latitude, 0.0001
          assert_in_delta 19.2143, message.longitude, 0.0001
          assert message.location?
        end

        test "accepts a single result hash without a results array and symbol keys" do
          message = InboundMessage.parse(
            from: "u3",
            message: { type: "TEXT", text: "Pozdrav" }
          )

          assert_equal "u3", message.sender
          assert_equal "Pozdrav", message.text
        end

        test "degrades gracefully on a missing/empty payload" do
          message = InboundMessage.parse({})

          assert_nil message.sender
          assert_nil message.text
          assert_nil message.image_url
          assert_nil message.latitude
          assert_nil message.longitude
          assert_not message.location?
        end

        test "treats blank text as nil" do
          message = InboundMessage.parse(
            "results" => [{ "from" => "u4", "message" => { "type" => "TEXT", "text" => "   " } }]
          )

          assert_nil message.text
        end
      end
    end
  end
end
