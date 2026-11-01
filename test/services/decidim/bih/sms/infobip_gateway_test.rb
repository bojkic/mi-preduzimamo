# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "stringio"

module Decidim
  module Bih
    module Sms
      class InfobipGatewayTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          clear_enqueued_jobs
          Decidim::Bih::Config.reset!
          @original_magic_link_short_path_enabled = Decidim::Bih.magic_link_short_path_enabled
        end

        teardown do
          clear_enqueued_jobs
          Decidim::Bih::Config.reset!
          Decidim::Bih.magic_link_short_path_enabled = @original_magic_link_short_path_enabled
        end

        test "implements Decidim's gateway contract" do
          gateway = InfobipGateway.new("38765111222", "1234", {})
          assert_equal "38765111222", gateway.mobile_phone_number
          assert_equal "1234", gateway.code
          assert_respond_to gateway, :deliver_code
        end

        test "logs and returns true when Infobip is unconfigured (dev fallback)" do
          fake = Struct.new(:configured?).new(false)
          logs = capture_logs do
            Decidim::Bih::Infobip::Client.stub(:new, fake) do
              assert InfobipGateway.new("38765111222", "1234").deliver_code
            end
          end

          assert_includes logs, "1234"
          assert_includes logs, "[phone:***1222]"
          assert_not_includes logs, "38765111222"
        end

        test "fails closed without logging OTP when Infobip is unconfigured in production" do
          fake = Struct.new(:configured?).new(false)
          logs = capture_logs do
            Rails.env.stub(:production?, true) do
              Decidim::Bih::Infobip::Client.stub(:new, fake) do
                assert_not InfobipGateway.new("38765111222", "1234").deliver_code
              end
            end
          end

          assert_not_includes logs, "1234"
          assert_not_includes logs, "38765111222"
          assert_includes logs, "[phone:***1222]"
        end

        test "delegates once to the shared ordered phone delivery policy" do
          calls = []
          fake = build_fake_client(send_phone_message: lambda { |**kwargs|
            calls << kwargs
            {}
          })

          Decidim::Bih::Infobip::Client.stub(:new, fake) do
            assert InfobipGateway.new(
              "+38765123456",
              "123456",
              organization: @organization,
              user: @user
            ).deliver_code
          end

          assert_equal 1, calls.size
          assert_equal "+38765123456", calls.first[:to]
          assert_equal "123456", calls.first[:otp_code], "WhatsApp receives the same code as the SMS fallback"
          assert_includes calls.first[:text], "123456"
          assert_includes calls.first[:text], "/v/"
          assert_includes calls.first[:viber_text], "/v/"
          assert_not_includes calls.first[:viber_text], "123456", "Viber keeps the link-only presentation"
          assert_operator calls.first[:expires_at], :>, Time.current
        end

        test "returns false and redacts provider errors when ordered delivery fails" do
          fake = build_fake_client(
            send_phone_message: lambda do |**|
              raise Decidim::Bih::Infobip::Error, "Infobip API error: token=abc123 to=38765111222"
            end
          )

          logs = capture_logs do
            Decidim::Bih::Infobip::Client.stub(:new, fake) do
              assert_not InfobipGateway.new("38765111222", "1234").deliver_code
            end
          end

          assert_not_includes logs, "abc123"
          assert_not_includes logs, "38765111222"
          assert_includes logs, "[phone:***1222]"
        end

        # Without a user there is no user-bound token and so no one-tap link.
        # A typed code would still verify — Decidim's /sms/authorizations/edit
        # takes one, and so does the engine's own hidden-code page — but a
        # blank link means the caller lost the user, and quietly demoting every
        # citizen to typing six digits would hide that. Fail loudly instead.
        test "no user in context sends nothing, mints no token and reports failure" do
          count_before = Decidim::Bih::LoginToken.count
          calls = []
          fake = build_fake_client(send_phone_message: ->(**kwargs) { calls << kwargs })

          logs = capture_logs do
            Decidim::Bih::Infobip::Client.stub(:new, fake) do
              assert_not InfobipGateway.new(
                "+38765123456",
                "123456",
                organization: @organization
              ).deliver_code
            end
          end

          assert_empty calls
          assert_equal count_before, Decidim::Bih::LoginToken.count
          assert_includes logs, "magic link unavailable"
          assert_includes logs, "[phone:***3456]"
          assert_not_includes logs, "+38765123456"
        end

        test "the ordered delivery carries the link on both channels and the code on SMS only" do
          calls = []
          fake = build_fake_client(send_phone_message: ->(**kwargs) { calls << kwargs })

          Decidim::Bih::Infobip::Client.stub(:new, fake) do
            assert InfobipGateway.new(
              "+38765123456",
              "123456",
              organization: @organization,
              user: @user
            ).deliver_code
          end

          text = calls.first[:text]
          viber_text = calls.first[:viber_text]

          assert_match %r{https://#{Regexp.escape(@organization.host)}/v/[A-Za-z0-9_-]+}, text
          assert_match %r{https://#{Regexp.escape(@organization.host)}/v/[A-Za-z0-9_-]+}, viber_text
          assert_includes text, "123456"
          assert_not_includes viber_text, "123456"
          assert_match(
            %r{\AMI: 123456 je tvoj kod\. Ne dijeli ga\. Potvrda jednim dodirom: https://#{Regexp.escape(@organization.host)}/v/[A-Za-z0-9_-]+ \(vazi 24 sata\)\z},
            text
          )
          assert_no_match(/[^\u0000-\u007F]/, text)
          segments = Decidim::Bih::Sms::SegmentCounter.for(text)
          assert_equal :gsm7, segments[:encoding]
          assert_equal 1, segments[:segments],
                       "registration SMS must stay within one segment (#{segments[:characters]} GSM-7 units)"

          longest_url = "https://#{"h" * 25}/v/#{"t" * 32}"
          longest_text = InfobipGateway.new(
            "+38765123456", "123456", organization: @organization, user: @user
          ).send(:sms_text, longest_url)
          longest_segments = Decidim::Bih::Sms::SegmentCounter.for(longest_text)
          assert_equal :gsm7, longest_segments[:encoding]
          assert_equal 1, longest_segments[:segments],
                       "longest production link must stay within one segment (#{longest_segments[:characters]} GSM-7 units)"
        end

        test "Cyrillic readers receive Latin SMS and Cyrillic link-only Viber text" do
          url = "https://#{@organization.host}/v/synthetic-token"
          gateway = InfobipGateway.new("+38765123456", "123456",
                                       organization: @organization, user: @user)

          I18n.with_locale(:"sr-Cyrl") do
            text = gateway.send(:sms_text, url)
            viber_text = gateway.send(:viber_text, url)

            assert_includes text, "MI: 123456 je tvoj kod. Ne dijeli ga. Potvrda jednim dodirom: #{url}"
            assert_includes text, "(vazi 24 sata)"
            assert_no_match(/[\p{Cyrillic}]/, text)
            assert_includes viber_text, "МИ:"
            assert_includes viber_text, url
            assert_not_includes viber_text, "123456"
          end
        end

        test "the delivery channels the form collected reach the gateway client" do
          calls = []
          fake = build_fake_client(send_phone_message: ->(**kwargs) { calls << kwargs })

          Decidim::Bih::Infobip::Client.stub(:new, fake) do
            assert InfobipGateway.new(
              "+38765123456",
              "123456",
              organization: @organization,
              user: @user,
              channels: [:sms]
            ).deliver_code
          end

          assert_equal [:sms], calls.first[:channels]
        end

        # --- Token binding (Round 14 correctness) ---

        test "the OTP message carries a magic link when the user is known" do
          gateway = InfobipGateway.new("+38765123456", "123456",
                                       organization: @organization, user: @user)
          text = gateway.send(:message_text)
          token = Decidim::Bih::LoginToken.last
          assert token, "a verify token must be minted"
          assert_match %r{https://#{Regexp.escape(@organization.host)}/v/[A-Za-z0-9_-]+}, text
          assert_includes text, "123456"
        end

        test "the OTP magic link follows the configured path" do
          Decidim::Bih.magic_link_short_path_enabled = false

          gateway = InfobipGateway.new("+38765123456", "123456",
                                       organization: @organization, user: @user)
          text = gateway.send(:message_text)

          assert_match %r{https://#{Regexp.escape(@organization.host)}/biceriseno/v/[A-Za-z0-9_-]+}, text
        end

        test "no user in context means a plain code message and no token" do
          count_before = Decidim::Bih::LoginToken.count
          gateway = InfobipGateway.new("+38765123456", "123456", organization: @organization)
          text = gateway.send(:message_text)
          assert_includes text, "123456"
          assert_no_match %r{/v/}, text
          assert_equal count_before, Decidim::Bih::LoginToken.count
        end

        test "token stores the phone exactly as Decidim sanitized it (as-typed)" do
          gateway = InfobipGateway.new("+38765123456", "123456",
                                       organization: @organization, user: @user)
          gateway.send(:message_text)
          token = Decidim::Bih::LoginToken.last
          assert_not_nil token
          assert_equal "+38765123456", token.phone
        end

        test "token is minted exactly once per ordered delivery" do
          token_count_before = Decidim::Bih::LoginToken.count
          fake = build_fake_client(send_phone_message: ->(**) { {} })

          Decidim::Bih::Infobip::Client.stub(:new, fake) do
            InfobipGateway.new("+38765123456", "123456",
                               organization: @organization, user: @user).deliver_code
          end

          assert_equal token_count_before + 1, Decidim::Bih::LoginToken.count,
                       "exactly one token must be minted per deliver_code call"
        end

        # --- local-number normalization + binding correctness ---

        test "local-format number: delivery is normalized to E.164, token phone is as-typed" do
          local_phone = "066900004"
          unique_id = Digest::SHA256.hexdigest(
            "#{local_phone}-#{Rails.application.secret_key_base}"
          )
          FactoryBot.create(
            :authorization,
            user: @user,
            name: "sms",
            unique_id: unique_id,
            granted_at: nil,
            verification_metadata: {
              "verification_code" => "999001",
              "code_sent_at" => 2.minutes.ago.iso8601
            }
          )

          captured_to = nil
          fake = build_fake_client(send_phone_message: lambda { |to:, **|
            captured_to = to
            {}
          })

          Decidim::Bih::Infobip::Client.stub(:new, fake) do
            gateway = InfobipGateway.new(local_phone, "999001",
                                         organization: @organization, user: @user)
            gateway.deliver_code
          end

          assert_equal local_phone, captured_to,
                       "gateway must pass as-typed number to client (client normalizes)"

          token = Decidim::Bih::LoginToken.last
          assert_not_nil token
          assert_equal local_phone, token.phone,
                       "token.phone must equal the as-typed sanitized number for unique_id binding"

          auth = Decidim::Authorization.find_by(user: @user, name: "sms")
          granter = Object.new.extend(Decidim::Bih::GrantsSmsAuthorization)
          granter.grant_sms_authorization(@user, {}, expected_phone: token.phone)
          assert auth.reload.granted?,
                 "GrantsSmsAuthorization must grant the pending auth when token.phone matches the as-typed unique_id"
        end

        test "international-format number: token phone is as-typed, grant matches" do
          intl_phone = "+38765123456"
          unique_id = Digest::SHA256.hexdigest(
            "#{intl_phone}-#{Rails.application.secret_key_base}"
          )
          FactoryBot.create(
            :authorization,
            user: @user,
            name: "sms",
            unique_id: unique_id,
            granted_at: nil,
            verification_metadata: {
              "verification_code" => "111222",
              "code_sent_at" => 2.minutes.ago.iso8601
            }
          )

          fake = build_fake_client(send_phone_message: ->(**) { {} })

          Decidim::Bih::Infobip::Client.stub(:new, fake) do
            gateway = InfobipGateway.new(intl_phone, "111222",
                                         organization: @organization, user: @user)
            gateway.deliver_code
          end

          token = Decidim::Bih::LoginToken.last
          assert_not_nil token
          assert_equal intl_phone, token.phone

          auth = Decidim::Authorization.find_by(user: @user, name: "sms")
          granter = Object.new.extend(Decidim::Bih::GrantsSmsAuthorization)
          granter.grant_sms_authorization(@user, {}, expected_phone: token.phone)
          assert auth.reload.granted?,
                 "grant must succeed for international-format phone when token.phone matches as-typed unique_id"
        end

        # --- what the form hands the gateway (SmsGatewayContextOverride) ---

        test "the form hands the gateway the user and the channels it collected" do
          form = Decidim::Verifications::Sms::MobilePhoneForm.from_params(
            user: @user,
            mobile_phone_number: "+387 65 123 456",
            delivery_channels: ["sms"]
          )

          context = form.send(:sms_gateway_context)

          assert_equal @user, context[:user]
          assert_equal @organization, context[:organization]
          assert_equal ["sms"], context[:channels]
        end

        # delivery_channels is unfiltered request data and
        # Infobip::Client#normalize_phone_channel_subset calls #to_s.to_sym on
        # every element, so the attribute is typed [String]: a nested Hash in
        # the parameter must arrive as a String, not as a Hash that blows up
        # mid-send.
        test "a channel list from request params reaches the gateway as strings" do
          form = Decidim::Verifications::Sms::MobilePhoneForm.from_params(
            user: @user,
            mobile_phone_number: "+387 65 123 456",
            delivery_channels: [{ "x" => 1 }, "sms"]
          )

          channels = form.send(:sms_gateway_context)[:channels]

          assert(channels.all?(String), "every channel must be a String, got #{channels.map(&:class).inspect}")
          assert_includes channels, "sms"
          assert_nothing_raised { channels.map(&:to_sym) }
        end

        test "a form with no channel choice leaves delivery unrestricted" do
          form = Decidim::Verifications::Sms::MobilePhoneForm.from_params(
            user: @user,
            mobile_phone_number: "+387 65 123 456"
          )

          # Blank is how Infobip::Client#normalize_phone_channel_subset spells
          # "every configured channel, in the usual order" — the attribute
          # defaults to [], not nil, so the empty array has to mean that too.
          assert_predicate form.send(:sms_gateway_context)[:channels], :blank?
        end

        private

        def build_fake_client(send_phone_message:)
          fake = Object.new
          fake.define_singleton_method(:configured?) { true }
          fake.define_singleton_method(:send_phone_message) { |**kwargs| send_phone_message.call(**kwargs) }
          fake
        end

        def capture_logs
          io = StringIO.new
          original_logger = Rails.logger
          Rails.logger = ActiveSupport::Logger.new(io)
          yield
          io.string
        ensure
          Rails.logger = original_logger
        end
      end
    end
  end
end
