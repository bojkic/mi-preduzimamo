# frozen_string_literal: true

require "test_helper"
require "capybara"
require_relative "../../support/synthetic_launch_event"

module DecidimApp
  class LaunchEventTest < ActionDispatch::IntegrationTest
    include Devise::Test::IntegrationHelpers
    include ActiveJob::TestHelper
    include SyntheticLaunchEvent

    setup do
      travel_to Time.utc(2040, 9, 19, 17)
      @organization = create_organization
      install_synthetic_launch_event(organization: @organization, opens_at: "2040-09-19T00:00:00+02:00",
        closes_at: "2040-09-20T00:00:00+02:00", sms_fallback: true)
      @event_key = LaunchEvent.event_key(@organization)
      host! @organization.host
      @user = create(:user, :confirmed, organization: @organization)
      @admin = create(:user, :admin, :confirmed, organization: @organization)
      @phone = "+12025550101"
      Decidim::Authorization.create!(user: @user, name: "sms", granted_at: Time.current,
                                    unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(@phone))
      Decidim::Bih::VerifiedPhone.synchronize!(user: @user, organization: @organization, phone: @phone)
    end

    teardown do
      restore_synthetic_launch_event
      travel_back
    end

    test "poll renders all seven choices and aggregate results anonymously" do
      get "/lansiranje/anketa"
      assert_response :success
      LaunchEvent::CHOICES.each_value { |label| assert_includes response.body, label }
      assert_select "progress", count: 7
      assert_select "form[data-event-vote]", count: 0
      get "/lansiranje/anketa/rezultati"
      assert_equal 0, response.parsed_body["total"]
      assert_equal 7, response.parsed_body["choices"].size
    end

    test "verified citizen votes once and repeat POST cannot change the first vote" do
      sign_in @user
      post "/lansiranje/anketa/glas", params: { choice: "roads", event_key: @event_key }, as: :json
      assert_response :success
      assert_equal "roads", response.parsed_body["voted"]
      assert_equal 1, response.parsed_body["total"]
      post "/lansiranje/anketa/glas", params: { choice: "waste", event_key: @event_key }, as: :json
      assert_response :success
      assert_equal "roads", response.parsed_body["voted"]
      assert_equal 1, LaunchEventVote.where(organization: @organization).count
      get "/lansiranje/anketa"
      assert_response :success
      assert_select "form[data-event-vote]", count: 0
      assert_includes response.body, "Tvoj glas je zabilježen"
    end

    test "invalid options and unverified citizens cannot vote" do
      sign_in @user
      post "/lansiranje/anketa/glas", params: { choice: "invented", event_key: @event_key }, as: :json
      assert_response :unprocessable_entity
      Decidim::Authorization.where(user: @user).delete_all
      post "/lansiranje/anketa/glas", params: { choice: "roads", event_key: @event_key }, as: :json
      assert_response :forbidden
      assert_equal 0, LaunchEventVote.where(organization: @organization).count
    end

    test "poll results stay within organization" do
      LaunchEventVote.create!(organization: @organization, user: @user, event_key: @event_key, choice: "water")
      other = create_organization
      host! other.host
      get "/lansiranje/anketa/rezultati"
      assert_response :success
      assert_equal 0, response.parsed_body["total"]
    end

    test "event closes at local midnight and results remain readable" do
      sign_in @user
      travel_to Time.utc(2040, 9, 19, 22)
      assert_not LaunchEvent.open?(@organization)
      post "/lansiranje/anketa/glas", params: { choice: "roads", event_key: @event_key }, as: :json
      assert_response :unprocessable_entity
      get "/lansiranje/anketa/rezultati"
      assert_response :success
    end

    test "personal link GET is inert and POST signs in to the map exactly once" do
      raw, delivery = issued_link("map")
      2.times { get "/v/#{raw}"; assert_response :success }
      assert_nil delivery.reload.consumed_at
      assert_includes response.headers["Cache-Control"], "no-store"
      assert_equal "strict-origin", response.headers["Referrer-Policy"]
      assert_select "link[rel=canonical]", count: 0
      assert_select "form[action='/v/#{raw}']", count: 1
      post "/v/#{raw}"
      assert_redirected_to "/biceriseno/mapa"
      assert delivery.reload.consumed_at
      get "/lansiranje/anketa"
      assert_select "form[data-event-vote]", count: 1
      sign_out @user
      post "/v/#{raw}"
      assert_response :unprocessable_entity
    end

    test "two messages retain independent personal links" do
      map_raw, map_delivery = issued_link("map")
      poll_raw, poll_delivery = issued_link("poll")
      get "/v/#{map_raw}"
      assert_response :success
      post "/v/#{poll_raw}"
      assert_redirected_to "/lansiranje/anketa"
      assert_nil map_delivery.reload.consumed_at
      assert poll_delivery.reload.consumed_at
    end

    test "foreign organization revoked phone expired link and blocked user cannot sign in" do
      raw, delivery = issued_link("map")
      other = create_organization
      host! other.host
      post "/v/#{raw}"
      assert_response :unprocessable_entity
      host! @organization.host
      delivery.update!(expires_at: 1.second.ago)
      post "/v/#{raw}"
      assert_response :unprocessable_entity
      delivery.update!(expires_at: LaunchEvent.closes_at(@organization))
      @user.update!(blocked: true)
      post "/v/#{raw}"
      assert_response :unprocessable_entity
      @user.update!(blocked: false)
      Decidim::Authorization.where(user: @user).delete_all
      post "/v/#{raw}"
      assert_response :unprocessable_entity
      assert_nil delivery.reload.consumed_at
    end

    test "link cannot silently switch an already signed in account" do
      raw, delivery = issued_link("poll")
      sign_in @admin
      post "/v/#{raw}"
      assert_response :unprocessable_entity
      assert_nil delivery.reload.consumed_at
    end

    test "citizen cannot access send controls or enqueue messages" do
      sign_in @user
      get "/admin/lansiranje"
      assert_redirected_to "/admin/"
      assert_no_enqueued_jobs do
        post "/admin/lansiranje/posalji", params: { message_key: "map", event_key: @event_key, confirm: "1" }
        assert_redirected_to "/admin/"
      end
      assert_equal 0, LaunchEventDelivery.where(organization: @organization).count
    end

    test "admin sees both previews and must explicitly confirm live send" do
      sign_in @admin
      LaunchEvent.stub(:channels_for, ["viber"]) do
        get "/admin/lansiranje"
        assert_response :success
        assert_includes response.body, "1. Mapa prijava"
        assert_includes response.body, "2. Anketa o komšiluku"
        assert_no_enqueued_jobs do
          post "/admin/lansiranje/posalji", params: { message_key: "map", event_key: @event_key }
          assert_response :unprocessable_entity
        end
      end
    end

    test "delivery makes one provider request and stores no raw personal link" do
      delivery = LaunchEventDelivery.create!(organization: @organization, user: @user, actor: @admin,
        event_key: @event_key, message_key: "map", expires_at: LaunchEvent.closes_at(@organization))
      client = Minitest::Mock.new
      client.expect(:send_phone_message, { "messages" => [{ "messageId" => "test-delivery" }] }) do |**kwargs|
        assert_equal @phone, kwargs[:to]
        assert_equal ["viber"], kwargs[:channels]
        assert_equal false, kwargs[:final_sms]
        assert_match %r{/v/event-[A-Za-z0-9_-]{32}}, kwargs[:text]
        true
      end
      LaunchEvent.stub(:channels_for, ["viber"]) do
        Decidim::Bih::Infobip::Client.stub(:new, client) do
          LaunchEvent.deliver!(delivery)
          LaunchEvent.deliver!(delivery)
        end
      end
      client.verify
      assert_equal "accepted", delivery.reload.status
      assert_equal ["test-delivery"], delivery.provider_message_ids
      assert_not_includes delivery.attributes.to_json, "/v/event-"
    end

    test "event delivery requests Viber with SMS fallback and GSM-safe SMS text" do
      delivery = LaunchEventDelivery.create!(organization: @organization, user: @user, actor: @admin,
        event_key: @event_key, message_key: "poll", expires_at: LaunchEvent.closes_at(@organization))
      client = Minitest::Mock.new
      client.expect(:send_phone_message, { "messages" => [{ "messageId" => "test-fallback" }] }) do |**kwargs|
        assert_equal %w(viber sms), kwargs[:channels]
        assert kwargs[:final_sms]
        assert_equal 60, kwargs[:channel_validity_seconds]
        assert_match(/komšinica/, kwargs[:viber_text])
        assert_match(/komsinica/, kwargs[:text])
        assert kwargs[:text].ascii_only?
        true
      end
      LaunchEvent.stub(:channels_for, %w(viber sms)) do
        Decidim::Bih::Infobip::Client.stub(:new, client) { LaunchEvent.deliver!(delivery) }
      end
      client.verify
      assert_equal "accepted", delivery.reload.status
    end

    test "a later SMS success can replace an earlier Viber failure receipt" do
      delivery = LaunchEventDelivery.create!(organization: @organization, user: @user, actor: @admin,
        event_key: @event_key, message_key: "map", expires_at: LaunchEvent.closes_at(@organization),
        status: "accepted", provider_message_ids: ["test-fallback-receipt"])
      client = Minitest::Mock.new
      client.expect(:message_delivery_reports, { "results" => [{ "messageId" => "test-fallback-receipt", "status" => { "groupName" => "UNDELIVERABLE", "name" => "VIBER_UNAVAILABLE" } }] }, message_id: "test-fallback-receipt")
      client.expect(:message_delivery_reports, { "results" => [{ "messageId" => "test-fallback-receipt", "status" => { "groupName" => "DELIVERED", "name" => "DELIVERED_TO_HANDSET" } }] }, message_id: "test-fallback-receipt")
      Decidim::Bih::Infobip::Client.stub(:new, client) do
        assert_enqueued_jobs 1, only: LaunchEventReceiptJob do
          LaunchEventReceiptJob.perform_now(delivery.id)
        end
        assert_equal "rejected", delivery.reload.status
        LaunchEventReceiptJob.perform_now(delivery.id, 1)
      end
      client.verify
      assert_equal "delivered", delivery.reload.status
    end

    test "uncertain provider send is not retried" do
      delivery = LaunchEventDelivery.create!(organization: @organization, user: @user, actor: @admin,
        event_key: @event_key, message_key: "poll", expires_at: LaunchEvent.closes_at(@organization))
      calls = 0
      client = Object.new
      client.define_singleton_method(:send_phone_message) { |**_kwargs| calls += 1; raise Timeout::Error }
      LaunchEvent.stub(:channels_for, ["viber"]) do
        Decidim::Bih::Infobip::Client.stub(:new, client) { 2.times { LaunchEvent.deliver!(delivery) } }
      end
      assert_equal 1, calls
      assert_equal "unknown", delivery.reload.status
    end

    test "test and live message identities are distinct and repeated triggers deduplicate" do
      LaunchEvent.stub(:channels_for, ["viber"]) do
        2.times { LaunchEvent.enqueue!(organization: @organization, key: "map", actor: @admin, expected_event_key: @event_key) }
      end
      assert_equal 1, LaunchEventDelivery.where(user: @user, message_key: "map", test_message: false).count
      # A committed claim must never be queued on another trigger.
      LaunchEventDelivery.update_all(status: "accepted")
      LaunchEvent.stub(:channels_for, ["viber"]) do
        assert_no_enqueued_jobs { LaunchEvent.enqueue!(organization: @organization, key: "map", actor: @admin, expected_event_key: @event_key) }
        assert_enqueued_jobs 1 do
          LaunchEvent.enqueue!(organization: @organization, key: "map", actor: @admin, expected_event_key: @event_key, test_user: @admin)
        end
      end
      assert_equal 1, LaunchEventDelivery.where(user: @admin, test_message: true).count
    end

    test "database rejects a second vote even if model checks are bypassed" do
      attrs = { organization: @organization, user: @user, event_key: @event_key, choice: "roads" }
      LaunchEventVote.create!(**attrs)
      assert_raises ActiveRecord::RecordNotUnique do
        LaunchEventVote.transaction(requires_new: true) { LaunchEventVote.create!(**attrs.merge(choice: "waste")) }
      end
      assert_equal 1, LaunchEventVote.where(organization: @organization).count
    end

    test "opted out recipient and revoked phone are skipped before dispatch" do
      Decidim::Bih::TopicPreferences.set!(@user, topic: :platform_news, enabled: false)
      assert_empty LaunchEvent.channels_for(@user, @organization)
      Decidim::Bih::TopicPreferences.set!(@user, topic: :platform_news, enabled: true)
      Decidim::Authorization.where(user: @user).delete_all
      assert_empty LaunchEvent.channels_for(@user, @organization)
    end

    test "token route and poll vote enforce CSRF outside the test default" do
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      raw, delivery = issued_link("poll")
      post "/v/#{raw}"
      assert_response :unprocessable_entity
      assert_nil delivery.reload.consumed_at
      sign_in @user
      post "/lansiranje/anketa/glas", params: { choice: "roads", event_key: @event_key }
      assert_response :unprocessable_entity
      assert_equal 0, LaunchEventVote.where(organization: @organization).count
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

    test "unconfigured disabled or foreign event cannot enqueue vote or construct a provider" do
      variants = [-> { ENV.delete("MI_LAUNCH_EVENT_CONFIG_PATH") },
                  -> { write_synthetic_launch_event(enabled: false) },
                  -> { write_synthetic_launch_event(enabled: true, organization_host: "foreign.example.invalid", source_url: "https://foreign.example.invalid/event") }]
      variants.each do |change|
        change.call
        Decidim::Bih::Infobip::Client.stub(:new, -> { flunk "disabled event attempted provider setup" }) do
          assert_empty LaunchEvent.channels_for(@user, @organization)
          assert_no_enqueued_jobs do
            assert_raises(ArgumentError) { LaunchEvent.enqueue!(organization: @organization, key: "map", actor: @admin, expected_event_key: @event_key) }
          end
        end
        sign_in @user
        get "/lansiranje/anketa"
        assert_response :success
        assert_select "form[data-event-vote]", count: 0
        post "/lansiranje/anketa/glas", params: { choice: "roads", event_key: @event_key }, as: :json
        assert_response :unprocessable_entity
        assert_equal 0, LaunchEventVote.where(organization: @organization).count
      end
    end

    test "stale admin preview queues nothing while a refreshed identity can queue the current event" do
      sign_in @admin
      LaunchEvent.stub(:channels_for, ["viber"]) do
        get "/admin/lansiranje"
        assert_response :success
        assert_select "input[name=event_key][value=?]", @event_key
        write_synthetic_launch_event(title: "DRUGI AUTORSKI DOGAĐAJ")
        assert_no_enqueued_jobs do
          post "/admin/lansiranje/posalji", params: { message_key: "map", event_key: @event_key, confirm: "1" }
          assert_redirected_to "/admin/lansiranje"
        end
        assert_equal 0, LaunchEventDelivery.where(organization: @organization).count
        current = LaunchEvent.event_key(@organization)
        assert_not_equal @event_key, current
        assert_enqueued_jobs 1, only: LaunchEventDeliveryJob do
          post "/admin/lansiranje/posalji", params: { message_key: "map", event_key: current, confirm: "1" }
        end
        assert_equal [current], LaunchEventDelivery.where(organization: @organization).pluck(:event_key).uniq
      end
    end

    test "a stale vote form and stale aggregate poll cannot target a replacement event" do
      sign_in @user
      write_synthetic_launch_event(title: "DRUGI AUTORSKI DOGAĐAJ")
      post "/lansiranje/anketa/glas", params: { choice: "roads", event_key: @event_key }, as: :json
      assert_response :unprocessable_entity
      assert_equal 0, LaunchEventVote.where(organization: @organization).count
      get "/lansiranje/anketa/rezultati", params: { event_key: @event_key }
      assert_response :conflict
      current = LaunchEvent.event_key(@organization)
      post "/lansiranje/anketa/glas", params: { choice: "roads", event_key: current }, as: :json
      assert_response :success
      assert_equal current, response.parsed_body.fetch("event_key")
      assert_equal 1, response.parsed_body.fetch("total")
    end

    test "queued delivery is skipped before provider setup after event settings change" do
      delivery = LaunchEventDelivery.create!(organization: @organization, user: @user, actor: @admin,
        event_key: @event_key, message_key: "map", expires_at: LaunchEvent.closes_at(@organization))
      write_synthetic_launch_event(title: "DRUGI AUTORSKI DOGAĐAJ")
      Decidim::Bih::Infobip::Client.stub(:new, -> { flunk "stale pending delivery reached provider" }) do
        LaunchEventDeliveryJob.perform_now(delivery.id)
      end
      assert_equal "skipped", delivery.reload.status
      assert_equal "event_configuration_changed", delivery.reason
      assert_nil delivery.attempted_at
    end

    test "configuration change at provider construction skips a committed claim without a request" do
      delivery = LaunchEventDelivery.create!(organization: @organization, user: @user, actor: @admin,
        event_key: @event_key, message_key: "map", expires_at: LaunchEvent.closes_at(@organization))
      calls = 0
      client = Object.new
      client.define_singleton_method(:send_phone_message) { |**| calls += 1; raise "unexpected provider handoff" }
      factory = -> { write_synthetic_launch_event(title: "PROMIJENJENO PRIJE HTTP-a"); client }
      LaunchEvent.stub(:channels_for, ["viber"]) do
        Decidim::Bih::Infobip::Client.stub(:new, factory) { LaunchEvent.deliver!(delivery) }
      end
      assert_equal 0, calls
      assert_equal "skipped", delivery.reload.status
      assert_equal "ineligible_or_event_changed", delivery.reason
      assert delivery.attempted_at
      assert_empty delivery.provider_message_ids
    end

    test "message template changes also invalidate pending work without rewriting historical rows" do
      delivery = LaunchEventDelivery.create!(organization: @organization, user: @user, actor: @admin,
        event_key: @event_key, message_key: "map", expires_at: LaunchEvent.closes_at(@organization))
      prior = LaunchEvent::MESSAGES
      changed = prior.deep_dup
      changed["map"][:text] = "AUTORSKI PROMIJENJENI SADRŽAJ"
      LaunchEvent.send(:remove_const, :MESSAGES)
      LaunchEvent.const_set(:MESSAGES, changed.freeze)
      LaunchEvent.deliver!(delivery)
      assert_equal "skipped", delivery.reload.status
      assert_equal @event_key, delivery.event_key
    ensure
      if prior
        LaunchEvent.send(:remove_const, :MESSAGES)
        LaunchEvent.const_set(:MESSAGES, prior)
      end
    end

    test "configuration replacement prevents old personal links from signing in or claiming tokens" do
      raw, delivery = issued_link("poll")
      write_synthetic_launch_event(title: "DRUGI AUTORSKI DOGAĐAJ")
      get "/v/#{raw}"
      assert_response :unprocessable_entity
      post "/v/#{raw}"
      assert_response :unprocessable_entity
      assert_nil delivery.reload.consumed_at
      assert_not delivery.claim_token!
    end

    test "old votes and receipt reconciliation remain historical after an event replacement" do
      vote = LaunchEventVote.create!(organization: @organization, user: @user, event_key: @event_key, choice: "water")
      delivery = LaunchEventDelivery.create!(organization: @organization, user: @user, actor: @admin,
        event_key: @event_key, message_key: "map", expires_at: LaunchEvent.closes_at(@organization),
        status: "accepted", provider_message_ids: ["authored-old-receipt"])
      write_synthetic_launch_event(title: "DRUGI AUTORSKI DOGAĐAJ")
      assert_equal 0, LaunchEvent.results(@organization).fetch(:total)
      assert_equal @event_key, vote.reload.event_key
      client = Minitest::Mock.new
      client.expect(:message_delivery_reports, { "results" => [{ "messageId" => "authored-old-receipt", "status" => { "groupName" => "DELIVERED" } }] }, message_id: "authored-old-receipt")
      Decidim::Bih::Infobip::Client.stub(:new, client) { LaunchEvent.reconcile!(delivery) }
      client.verify
      assert_equal "delivered", delivery.reload.status
      write_synthetic_launch_event(title: "AUTORSKI DAN ZAJEDNICE")
      assert_equal 1, LaunchEvent.results(@organization).fetch(:total)
    end

    test "missing event identity cannot bypass the vote or operator preview binding" do
      sign_in @user
      post "/lansiranje/anketa/glas", params: { choice: "roads" }, as: :json
      assert_response :unprocessable_entity
      assert_equal 0, LaunchEventVote.where(organization: @organization).count
      LaunchEvent.stub(:channels_for, ["viber"]) do
        assert_no_enqueued_jobs do
          assert_raises(ArgumentError) { LaunchEvent.enqueue!(organization: @organization, key: "map", actor: @admin, expected_event_key: "") }
        end
      end
    end

    test "actual channel policy requires explicit SMS activation as well as provider consent and optional traffic" do
      client = Object.new
      def client.configured? = true
      def client.viber_business_configured? = true
      Decidim::Bih::TopicPreferences.set!(@user, topic: :platform_news, enabled: true)
      Decidim::Bih::Infobip::Client.stub(:new, client) do
        Decidim::Bih::Config.stub(:infobip, { optional_traffic_enabled: true, sms_sender: "AUTHORED" }) do
          assert_equal %w(viber sms), LaunchEvent.channels_for(@user, @organization)
          write_synthetic_launch_event(sms_fallback: false)
          assert_equal ["viber"], LaunchEvent.channels_for(@user, @organization)
          Decidim::Bih::TopicPreferences.set!(@user, topic: :platform_news, enabled: false)
          assert_empty LaunchEvent.channels_for(@user, @organization)
        end
        Decidim::Bih::Config.stub(:infobip, { optional_traffic_enabled: false, sms_sender: "AUTHORED" }) do
          assert_empty LaunchEvent.channels_for(@user, @organization)
        end
      end
    end

    test "channel withdrawal after claim prevents the actual provider handoff" do
      delivery = LaunchEventDelivery.create!(organization: @organization, user: @user, actor: @admin,
        event_key: @event_key, message_key: "map", expires_at: LaunchEvent.closes_at(@organization))
      checks = calls = 0
      policy = ->(*, **) { checks += 1; checks == 1 ? ["viber"] : [] }
      client = Object.new
      client.define_singleton_method(:send_phone_message) { |**| calls += 1; raise "unexpected handoff" }
      LaunchEvent.stub(:channels_for, policy) do
        Decidim::Bih::Infobip::Client.stub(:new, client) { LaunchEvent.deliver!(delivery) }
      end
      assert_equal 2, checks
      assert_equal 0, calls
      assert_equal "skipped", delivery.reload.status
    end

    test "recipient ceiling still stops before creating or queueing any delivery" do
      LaunchEvent.stub(:citizens, Array.new(501, @user)) do
        assert_no_enqueued_jobs do
          error = assert_raises(ArgumentError) { LaunchEvent.enqueue!(organization: @organization, key: "map", actor: @admin, expected_event_key: @event_key) }
          assert_equal "Recipient ceiling exceeded", error.message
        end
      end
      assert_equal 0, LaunchEventDelivery.where(organization: @organization).count
    end

    private

    def issued_link(key)
      raw = "event-#{SecureRandom.urlsafe_base64(24)}"
      delivery = LaunchEventDelivery.create!(organization: @organization, user: @user, actor: @admin,
        event_key: @event_key, message_key: key, expires_at: LaunchEvent.closes_at(@organization),
        status: "accepted", token_digest: Digest::SHA256.hexdigest(raw), phone_digest: LaunchEvent.phone_digest(@phone))
      [raw, delivery]
    end
  end
end
