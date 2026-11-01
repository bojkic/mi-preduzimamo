# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

module Decidim
  module Bih
    module Infobip
      class ClientTest < ActiveSupport::TestCase
        BASE = "https://test.api.infobip.com"
        SEND_PATH = "#{BASE}/sms/2/text/advanced".freeze
        VIBER_PATH = "#{BASE}/viber/2/messages".freeze
        MESSAGES_PATH = "#{BASE}/messages-api/1/messages".freeze

        # Construct with explicit credentials so the test never touches the
        # global ENV (keeps it isolated from other tests in the same process).
        def client
          Client.new(base_url: BASE, api_key: "secret-key")
        end

        setup { WebMock.disable_net_connect!(allow_localhost: true) }
        teardown do
          Decidim::Bih::Config.reset!
          WebMock.reset!
          WebMock.allow_net_connect!
        end

        test "configured? requires both base_url and api_key" do
          assert client.configured?
          assert_not Client.new(base_url: nil, api_key: "k").configured?
          assert_not Client.new(base_url: BASE, api_key: nil).configured?
        end

        test "Viber transport readiness requires its own sender" do
          with_infobip_config(viber_bm_sender: "BusinessSender", viber_bot_sender: nil) do
            assert client.viber_business_configured?
            assert_not client.viber_bot_configured?
          end

          with_infobip_config(viber_bm_sender: nil, viber_bot_sender: "BotSender") do
            assert_not client.viber_business_configured?
            assert client.viber_bot_configured?
          end
        end

        test "send_sms posts to the advanced endpoint with App auth and returns parsed body" do
          stub = stub_request(:post, SEND_PATH)
                 .with(
                   headers: { "Authorization" => "App secret-key", "Content-Type" => "application/json" },
                   body: hash_including("messages" => [hash_including("from" => "LFTest")])
                 )
                 .to_return(status: 200, body: { messages: [{ status: { name: "PENDING_ACCEPTED" } }] }.to_json,
                            headers: { "Content-Type" => "application/json" })

          result = client.send_sms(to: "+387 65 111 222", text: "Kod: 1234", from: "LFTest")

          assert_requested(stub)
          assert_equal "PENDING_ACCEPTED", result.dig("messages", 0, "status", "name")
        end

        # Table-driven: verify normalize_msisdn for all meaningful BiH input shapes.
        # Every row: [input, expected_output] — all must yield "38766900004".
        NORMALIZE_CASES = [
          # input                  expected          scenario
          ["066900004", "38766900004"], # local format (leading 0)
          ["066 900 004", "38766900004"], # local with spaces
          ["66900004", "38766900004"], # bare national (no leading 0)
          ["+38766900004", "38766900004"], # international with +
          ["38766900004", "38766900004"], # already international, no +
          ["0038766900004", "38766900004"] # international with 00 prefix
        ].freeze

        NORMALIZE_CASES.each do |(input, expected)|
          test "normalize_msisdn(#{input.inspect}) => #{expected.inspect}" do
            assert_equal expected, client.send(:normalize_msisdn, input)
          end
        end

        test "normalize_msisdn returns blank input as-is (lets the API surface the error)" do
          assert_equal "", client.send(:normalize_msisdn, "")
          assert_equal "", client.send(:normalize_msisdn, nil)
        end

        test "send_sms normalizes the destination to E.164 digits (+ → drop, country code added)" do
          stub = stub_request(:post, SEND_PATH)
                 .with(body: hash_including(
                   "messages" => [hash_including("destinations" => [{ "to" => "38765111222" }])]
                 ))
                 .to_return(status: 200, body: "{}")

          client.send_sms(to: "+387 65/111-222", text: "x", from: "LFTest")
          assert_requested(stub)
        end

        test "send_sms normalizes local-format destination to E.164" do
          stub = stub_request(:post, SEND_PATH)
                 .with(body: hash_including(
                   "messages" => [hash_including("destinations" => [{ "to" => "38766900004" }])]
                 ))
                 .to_return(status: 200, body: "{}")

          client.send_sms(to: "066900004", text: "x", from: "LFTest")
          assert_requested(stub)
        end

        test "send_viber normalizes local-format destination to E.164" do
          stub = stub_request(:post, VIBER_PATH)
                 .with(body: hash_including(
                   "messages" => [hash_including("destinations" => [{ "to" => "38766900004" }])]
                 ))
                 .to_return(status: 200, body: "{}")

          client.send_viber(to: "066900004", text: "x", sender: "ViberBN")
          assert_requested(stub)
        end

        test "raises on a non-success response" do
          body = { requestError: { serviceException: { api_key: "secret-key", to: "38765111222" } } }.to_json
          stub_request(:post, SEND_PATH).to_return(status: 401, body: body)
          error = assert_raises(Decidim::Bih::Infobip::Error) { client.send_sms(to: "38765111222", text: "x", from: "X") }

          assert_includes error.message, "Infobip API error (HTTP 401)"
          assert_not_includes error.message, "secret-key"
          assert_not_includes error.message, "38765111222"
          assert_includes error.message, "[phone:***1222]"
        end

        test "raises when unconfigured" do
          assert_raises(Decidim::Bih::Infobip::Error) do
            Client.new(base_url: nil, api_key: nil).send_sms(to: "38765111222", text: "x", from: "X")
          end
        end

        test "send_viber posts a TEXT message with App auth and returns parsed body" do
          stub = stub_request(:post, VIBER_PATH)
                 .with(
                   headers: { "Authorization" => "App secret-key", "Content-Type" => "application/json" },
                   body: hash_including(
                     "messages" => [hash_including(
                       "sender" => "ViberBN",
                       "destinations" => [{ "to" => "38765111222" }],
                       "content" => { "type" => "TEXT", "text" => "Zdravo" }
                     )]
                   )
                 )
                 .to_return(status: 200, body: { messages: [{ status: { name: "PENDING_ACCEPTED" } }] }.to_json,
                            headers: { "Content-Type" => "application/json" })

          result = client.send_viber(to: "+387 65/111-222", text: "Zdravo", sender: "ViberBN")

          assert_requested(stub)
          assert_equal "PENDING_ACCEPTED", result.dig("messages", 0, "status", "name")
        end

        test "send_viber raises on a non-success response" do
          stub_request(:post, VIBER_PATH).to_return(status: 400, body: { token: "abc123", to: "38765111222" }.to_json)
          error = assert_raises(Decidim::Bih::Infobip::Error) do
            client.send_viber(to: "38765111222", text: "x", sender: "ViberBN")
          end

          assert_not_includes error.message, "abc123"
          assert_not_includes error.message, "38765111222"
        end

        test "send_viber_bot preserves the opaque user id and uses VIBER_BOT" do
          stub = stub_request(:post, MESSAGES_PATH)
                 .with(
                   body: {
                     messages: [
                       {
                         channel: "VIBER_BOT",
                         sender: "MiBot",
                         destinations: [{ to: "opaque-user:A_42" }],
                         content: { body: { type: "TEXT", text: "Zdravo" } },
                         options: { adaptationMode: false }
                       }
                     ]
                   }
                 )
                 .to_return(status: 200, body: { messages: [{ messageId: "bot-accepted" }] }.to_json)

          result = client.send_viber_bot(to: "opaque-user:A_42", text: "Zdravo", sender: "MiBot")

          assert_requested(stub)
          assert_equal "bot-accepted", result.dig("messages", 0, "messageId")
        end

        test "send_viber_bot requires the Bot sender instead of reusing Business Messages sender" do
          error = assert_raises(Decidim::Bih::Infobip::Error) do
            client.send_viber_bot(to: "opaque-user:A_42", text: "Zdravo", sender: nil)
          end

          assert_includes error.message, "INFOBIP_VIBER_BOT_SENDER"
          assert_not_requested(:post, MESSAGES_PATH)
        end

        test "send_viber_bot_image preserves opaque user id and sends the Messages API image shape" do
          stub = stub_request(:post, MESSAGES_PATH)
                 .with(body: hash_including(
                   "messages" => [hash_including(
                     "channel" => "VIBER_BOT",
                     "sender" => "MiBot",
                     "destinations" => [{ "to" => "opaque-user:A_42" }],
                     "content" => {
                       "body" => {
                         "type" => "IMAGE",
                         "url" => "https://mi.example.com/sticker.png",
                         "text" => "Bravo!"
                       }
                     }
                   )]
                 ))
                 .to_return(status: 200, body: "{}")

          client.send_viber_bot_image(
            to: "opaque-user:A_42",
            image_url: "https://mi.example.com/sticker.png",
            text: "Bravo!",
            sender: "MiBot"
          )

          assert_requested(stub)
        end

        test "send_viber without sms_failover does not include smsFailover key in POST body" do
          stub = stub_request(:post, VIBER_PATH)
                 .with(body: lambda { |body|
                   parsed = JSON.parse(body)
                   parsed["messages"].none? { |m| m.dig("options", "smsFailover") }
                 })
                 .to_return(status: 200, body: "{}")

          client.send_viber(to: "+38765111222", text: "Zdravo", sender: "ViberBN")
          assert_requested(stub)
        end

        test "send_viber with sms_failover includes smsFailover block with sender, text, and validityPeriod" do
          stub = stub_request(:post, VIBER_PATH)
                 .with(body: hash_including(
                   "messages" => [hash_including(
                     "options" => hash_including(
                       "smsFailover" => {
                         "sender" => "LFBijeljina",
                         "text" => "Kod: 123456 — link: https://mi.example.com/v/abc",
                         "validityPeriod" => { "amount" => 2, "timeUnit" => "MINUTES" }
                       }
                     )
                   )]
                 ))
                 .to_return(status: 200, body: "{}")

          client.send_viber(
            to: "+38765111222",
            text: "Viber potvrdi",
            sender: "ViberBN",
            sms_failover: {
              sender: "LFBijeljina",
              text: "Kod: 123456 — link: https://mi.example.com/v/abc",
              validity_period: { amount: 2, timeUnit: "MINUTES" }
            }
          )
          assert_requested(stub)
        end

        test "send_viber with sms_failover uses default validity period when validity_period is omitted" do
          stub = stub_request(:post, VIBER_PATH)
                 .with(body: hash_including(
                   "messages" => [hash_including(
                     "options" => hash_including(
                       "smsFailover" => hash_including(
                         "validityPeriod" => { "amount" => 1, "timeUnit" => "MINUTES" }
                       )
                     )
                   )]
                 ))
                 .to_return(status: 200, body: "{}")

          client.send_viber(
            to: "+38765111222",
            text: "Potvrdi",
            sender: "ViberBN",
            sms_failover: { sender: "LFBijeljina", text: "Kod: 111" }
          )
          assert_requested(stub)
        end

        test "send_viber with sms_failover uses Config.infobip sms_sender as default when failover sender is blank" do
          with_infobip_config(sms_sender: "AuthoredSMS") do
            # Set up the default sender via ENV-independent approach:
            # The client reads this explicitly authored configuration at call time.
            stub = stub_request(:post, VIBER_PATH)
                   .with(body: hash_including(
                     "messages" => [hash_including(
                       "options" => hash_including(
                         "smsFailover" => hash_including("sender" => "AuthoredSMS")
                       )
                     )]
                   ))
                   .to_return(status: 200, body: "{}")

            client.send_viber(
              to: "+38765111222",
              text: "Potvrdi",
              sender: "ViberBN",
              sms_failover: { sender: nil, text: "Kod: 222" }
            )
            assert_requested(stub)
          end
        end

        test "send_viber puts primary validity and SMS failover inside message options" do
          stub = stub_request(:post, VIBER_PATH)
                 .with(body: hash_including(
                   "messages" => [hash_including(
                     "options" => {
                       "validityPeriod" => { "amount" => 30, "timeUnit" => "SECONDS" },
                       "smsFailover" => hash_including("text" => "SMS text")
                     }
                   )]
                 ))
                 .to_return(status: 200, body: "{}")

          client.send_viber(
            to: "+38765111222",
            text: "Viber text",
            sender: "ViberBN",
            validity_period: { amount: 30, timeUnit: "SECONDS" },
            sms_failover: { sender: "LFBijeljina", text: "SMS text" }
          )

          assert_requested(stub)
        end

        test "send_phone_message submits one provider-managed Viber WhatsApp AUTH SMS chain" do
          with_infobip_config(
            messages_api_enabled: true,
            viber_bm_sender: "ViberBN",
            whatsapp_sender: "38765000000",
            whatsapp_template_name: "mi_phone_message",
            whatsapp_template_language: "sr",
            messenger_sender: nil,
            sms_sender: "LFTest"
          ) do
            stub = stub_request(:post, MESSAGES_PATH)
                   .with(body: lambda { |body|
                     message = JSON.parse(body).fetch("messages").first
                     destinations = message.dig("destinations", 0, "byChannel")
                     failover = message.fetch("failover")

                     message.fetch("channel") == "VIBER_BM" &&
                     destinations.map { |item| item.fetch("channel") } == %w(VIBER_BM WHATSAPP SMS) &&
                       failover.map { |item| item.fetch("channel") } == %w(WHATSAPP SMS) &&
                       failover.first.dig("template", "templateName") == "mi_phone_message" &&
                       failover.first.dig("template", "language") == "sr" &&
                       failover.first.dig("content", "body") == { "1" => "123456", "type" => "TEXT" } &&
                       failover.first.dig("content", "buttons") == [{ "suffix" => "123456", "type" => "OPEN_URL" }] &&
                       failover.first.to_json.exclude?("Login link") &&
                       failover.last.dig("content", "body", "text") == "Login link; code 123456"
                   })
                   .to_return(status: 200, body: { messages: [{ messageId: "accepted" }] }.to_json)

            result = client.send_phone_message(
              to: "+387 65 111 222",
              text: "Login link; code 123456",
              viber_text: "Viber login link",
              expires_at: 10.minutes.from_now,
              otp_code: "123456"
            )

            assert_requested(stub)
            assert_equal "accepted", result.dig("messages", 0, "messageId")
          end
        end

        test "send_phone_message uses an approved Viber Business template when supplied" do
          with_infobip_config(
            messages_api_enabled: true,
            viber_bm_sender: "ViberBN",
            whatsapp_sender: nil,
            whatsapp_template_name: nil,
            messenger_sender: nil,
            sms_sender: "LFTest"
          ) do
            stub = stub_request(:post, MESSAGES_PATH)
                   .with(body: lambda { |body|
                     message = JSON.parse(body).fetch("messages").first
                     message.fetch("channel") == "VIBER_BM" &&
                       message.dig("template", "templateName") == "otp-template-uuid" &&
                       message.dig("template", "language") == "bs" &&
                       message.dig("content", "body") == { "pin" => "123456", "type" => "TEXT" }
                   })
                   .to_return(status: 200, body: "{}")

            client.send_phone_message(
              to: "+38765111222",
              text: "Kod: 123456",
              viber_template: {
                template_id: "otp-template-uuid",
                language: "bs",
                parameters: { pin: "123456" }
              }
            )

            assert_requested(stub)
          end
        end

        test "send_phone_message excludes Messenger even with a channel recipient id" do
          with_infobip_config(
            messages_api_enabled: true,
            viber_bm_sender: "ViberBN",
            whatsapp_sender: nil,
            whatsapp_template_name: nil,
            messenger_sender: "page-id",
            sms_sender: "LFTest"
          ) do
            stub = stub_request(:post, MESSAGES_PATH)
                   .with(body: lambda { |body|
                     message = JSON.parse(body).fetch("messages").first
                     destinations = message.dig("destinations", 0, "byChannel")
                     destinations.map { |item| [item.fetch("channel"), item.fetch("to")] } == [
                       %w(VIBER_BM 38765111222),
                       %w(SMS 38765111222)
                     ]
                   })
                   .to_return(status: 200, body: "{}")

            client.send_phone_message(
              to: "+38765111222",
              text: "Login link",
              messenger: { to: "messenger-recipient", session_active: true }
            )

            assert_requested(stub)
          end
        end

        test "send_phone_message skips Messenger without an active user-initiated session" do
          with_infobip_config(
            messages_api_enabled: true,
            viber_bm_sender: nil,
            whatsapp_sender: nil,
            whatsapp_template_name: nil,
            messenger_sender: "page-id",
            sms_sender: "LFTest"
          ) do
            sms_stub = stub_request(:post, SEND_PATH).to_return(status: 200, body: "{}")

            client.send_phone_message(
              to: "+38765111222",
              text: "Login link",
              messenger: { to: "messenger-recipient", session_active: false }
            )

            assert_requested(sms_stub)
            assert_not_requested(:post, MESSAGES_PATH)
          end
        end

        # A definitive 4xx means Infobip refused the request and queued nothing,
        # so the direct SMS below is the citizen's only message. A timeout or a
        # 5xx is ambiguous — the chain may already be accepted — and an SMS on
        # top of it is a second billed message for the same code (review
        # 2026-09-07, lane 1 H2 / lane 8 H-1).
        test "send_phone_message does not send a direct SMS when the Messages API times out" do
          with_infobip_config(
            messages_api_enabled: true,
            viber_bm_sender: "ViberBN",
            whatsapp_sender: nil,
            whatsapp_template_name: nil,
            messenger_sender: nil,
            sms_sender: "LFTest"
          ) do
            stub_request(:post, MESSAGES_PATH).to_timeout
            sms_stub = stub_request(:post, SEND_PATH).to_return(status: 200, body: "{}")

            error = assert_raises(Decidim::Bih::Infobip::Error) do
              client.send_phone_message(to: "+38765111222", text: "Login link")
            end

            assert_not_requested(sms_stub)
            assert_nil error.http_status, "a transport timeout carries no provider status"
          end
        end

        test "send_phone_message does not send a direct SMS on a provider 5xx" do
          with_infobip_config(
            messages_api_enabled: true,
            viber_bm_sender: "ViberBN",
            whatsapp_sender: nil,
            whatsapp_template_name: nil,
            messenger_sender: nil,
            sms_sender: "LFTest"
          ) do
            stub_request(:post, MESSAGES_PATH).to_return(status: 503, body: "{}")
            sms_stub = stub_request(:post, SEND_PATH).to_return(status: 200, body: "{}")

            assert_raises(Decidim::Bih::Infobip::Error) do
              client.send_phone_message(to: "+38765111222", text: "Login link")
            end

            assert_not_requested(sms_stub)
          end
        end

        # A 24-hour message may wait hours on the free channel; only an auth
        # code needs the short default (review 2026-09-07, lane 1 H1).
        test "send_phone_message applies the caller's channel validity to every non-final leg" do
          with_infobip_config(
            messages_api_enabled: true,
            viber_bm_sender: "ViberBN",
            whatsapp_sender: "38765000000",
            whatsapp_template_name: "mi_phone_message",
            whatsapp_template_language: "sr",
            messenger_sender: nil,
            sms_sender: "LFTest"
          ) do
            periods = nil
            stub = stub_request(:post, MESSAGES_PATH)
                   .with(body: lambda { |body|
                     message = JSON.parse(body).fetch("messages").first
                     periods = [message.dig("options", "validityPeriod")] +
                               message.fetch("failover").map { |item| item.fetch("validityPeriod") }
                     true
                   })
                   .to_return(status: 200, body: { messages: [{ messageId: "accepted" }] }.to_json)

            client.send_phone_message(
              to: "+38765111222",
              text: "Pozivnica",
              viber_text: "Pozivnica",
              whatsapp_template: { name: "mi_pozivnica_lansiranje_v1", language: "sr", body: { "1" => "MI-1" } },
              expires_at: 24.hours.from_now,
              channel_validity_seconds: 6.hours.to_i
            )

            assert_requested(stub)
            assert_equal([21_600, 21_600], periods.first(2).map { |period| period.fetch("amount") })
            assert_equal(%w(SECONDS SECONDS), periods.first(2).map { |period| period.fetch("timeUnit") })
            assert_operator periods.last.fetch("amount"), :>=, 43_000,
                            "the final SMS leg keeps the rest of the 24-hour window"
          end
        end

        test "send_phone_message falls back to direct SMS when Messages API rejects the request" do
          with_infobip_config(
            messages_api_enabled: true,
            viber_bm_sender: "ViberBN",
            whatsapp_sender: nil,
            whatsapp_template_name: nil,
            messenger_sender: nil,
            sms_sender: "LFTest"
          ) do
            stub_request(:post, MESSAGES_PATH).to_return(status: 403, body: '{"error":"scope"}')
            sms_stub = stub_request(:post, SEND_PATH).to_return(status: 200, body: "{}")

            client.send_phone_message(to: "+38765111222", text: "Login link")

            assert_requested(sms_stub)
          end
        end

        test "send_phone_message keeps native Viber to SMS failover before Messages API rollout" do
          with_infobip_config(
            messages_api_enabled: false,
            viber_bm_sender: "ViberBN",
            whatsapp_sender: "38765000000",
            whatsapp_template_name: "mi_phone_message",
            messenger_sender: "page-id",
            sms_sender: "LFTest"
          ) do
            stub = stub_request(:post, VIBER_PATH)
                   .with(body: lambda { |body|
                     message = JSON.parse(body).fetch("messages").first
                     message.fetch("sender") == "ViberBN" &&
                       message.dig("content", "text") == "Viber login link" &&
                       message.dig("options", "smsFailover", "sender") == "LFTest" &&
                       message.dig("options", "smsFailover", "text") == "Login link"
                   })
                   .to_return(status: 200, body: "{}")

            client.send_phone_message(
              to: "+38765111222",
              text: "Login link",
              viber_text: "Viber login link"
            )

            assert_requested(stub)
            assert_not_requested(:post, MESSAGES_PATH)
          end
        end

        test "legacy phone delivery sends an approved Viber OTP template with SMS failover" do
          with_infobip_config(
            messages_api_enabled: false,
            viber_bm_sender: "ViberBN",
            whatsapp_sender: nil,
            whatsapp_template_name: nil,
            messenger_sender: nil,
            sms_sender: "LFTest"
          ) do
            stub = stub_request(:post, VIBER_PATH)
                   .with(body: lambda { |body|
                     message = JSON.parse(body).fetch("messages").first
                     message.dig("content", "type") == "TEMPLATE" &&
                       message.dig("content", "templateId") == "otp-template-uuid" &&
                       message.dig("content", "parameters", "pin") == "123456" &&
                       message.dig("options", "smsFailover", "text") == "Kod: 123456"
                   })
                   .to_return(status: 200, body: "{}")

            client.send_phone_message(
              to: "+38765111222",
              text: "Kod: 123456",
              viber_template: {
                template_id: "otp-template-uuid",
                language: "bs",
                parameters: { pin: "123456" }
              }
            )

            assert_requested(stub)
          end
        end

        test "send_phone_message uses direct SMS when no earlier channel is eligible" do
          with_infobip_config(
            messages_api_enabled: true,
            viber_bm_sender: nil,
            whatsapp_sender: "38765000000",
            whatsapp_template_name: nil,
            messenger_sender: "page-id",
            sms_sender: "LFTest"
          ) do
            sms_stub = stub_request(:post, SEND_PATH).to_return(status: 200, body: "{}")

            client.send_phone_message(to: "+38765111222", text: "Login link")

            assert_requested(sms_stub)
            assert_not_requested(:post, MESSAGES_PATH)
          end
        end

        test "send_phone_message requires SMS as the final channel" do
          with_infobip_config(
            messages_api_enabled: true,
            viber_bm_sender: "ViberBN",
            whatsapp_sender: nil,
            whatsapp_template_name: nil,
            messenger_sender: nil,
            sms_sender: nil
          ) do
            error = assert_raises(Decidim::Bih::Infobip::Error) do
              client.send_phone_message(to: "+38765111222", text: "Login link")
            end

            assert_includes error.message, "INFOBIP_SMS_SENDER"
            assert_not_requested(:post, MESSAGES_PATH)
            assert_not_requested(:post, SEND_PATH)
          end
        end

        test "send_phone_message preserves final SMS when the token is near expiry" do
          with_infobip_config(
            messages_api_enabled: true,
            viber_bm_sender: "ViberBN",
            whatsapp_sender: "38765000000",
            whatsapp_template_name: "mi_phone_message",
            messenger_sender: nil,
            sms_sender: "LFTest"
          ) do
            sms_stub = stub_request(:post, SEND_PATH).to_return(status: 200, body: "{}")

            client.send_phone_message(
              to: "+38765111222",
              text: "Login link",
              expires_at: 5.seconds.from_now
            )

            assert_requested(sms_stub)
            assert_not_requested(:post, MESSAGES_PATH)
          end
        end

        test "send_viber_image posts an IMAGE message with the image url and returns parsed body" do
          stub = stub_request(:post, VIBER_PATH)
                 .with(
                   headers: { "Authorization" => "App secret-key" },
                   body: hash_including(
                     "messages" => [hash_including(
                       "sender" => "ViberBN",
                       "destinations" => [{ "to" => "38765111222" }],
                       "content" => { "type" => "IMAGE",
                                      "imageUrl" => "https://mi.example.com/mi/stickers/prijavljeno.png" }
                     )]
                   )
                 )
                 .to_return(status: 200, body: { messages: [{ status: { name: "PENDING_ACCEPTED" } }] }.to_json,
                            headers: { "Content-Type" => "application/json" })

          result = client.send_viber_image(to: "+387 65/111-222",
                                           image_url: "https://mi.example.com/mi/stickers/prijavljeno.png",
                                           sender: "ViberBN")

          assert_requested(stub)
          assert_equal "PENDING_ACCEPTED", result.dig("messages", 0, "status", "name")
        end

        test "send_viber_image includes an optional text caption only when given" do
          stub = stub_request(:post, VIBER_PATH)
                 .with(body: hash_including(
                   "messages" => [hash_including(
                     "content" => { "type" => "IMAGE",
                                    "imageUrl" => "https://mi.example.com/x.png",
                                    "text" => "Bravo!" }
                   )]
                 ))
                 .to_return(status: 200, body: "{}")

          client.send_viber_image(to: "38765111222", image_url: "https://mi.example.com/x.png",
                                  text: "Bravo!", sender: "ViberBN")
          assert_requested(stub)
        end

        test "send_viber_image raises on a non-success response" do
          stub_request(:post, VIBER_PATH).to_return(status: 400, body: "bad request")
          assert_raises(Decidim::Bih::Infobip::Error) do
            client.send_viber_image(to: "38765111222", image_url: "https://mi.example.com/x.png", sender: "ViberBN")
          end
        end

        private

        def with_infobip_config(overrides)
          original = Decidim::Bih::Config.infobip
          Decidim::Bih::Config.instance_variable_set(:@infobip, original.merge(overrides))
          yield
        ensure
          Decidim::Bih::Config.instance_variable_set(:@infobip, original)
        end
      end
    end
  end
end
