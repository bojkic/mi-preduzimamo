# frozen_string_literal: true

require "test_helper"
require Rails.root.join("installation/demo/phone_capture")

module DecidimApp
  class InstallationProfileTest < ActiveSupport::TestCase
    setup do
      @previous_factory = Decidim::Bih.phone_auth_demo_client_factory
      @previous_mail_adapter = ActionMailer::Base.delivery_method
      ActionMailer::Base.delivery_method = :test
      ActionMailer::Base.deliveries.clear
    end

    teardown do
      Decidim::Bih.phone_auth_demo_client_factory = @previous_factory
      ActionMailer::Base.delivery_method = @previous_mail_adapter
      ActionMailer::Base.deliveries.clear
    end

    test "unselected demo factory preserves real Infobip client selection" do
      Decidim::Bih.phone_auth_demo_client_factory = nil
      assert_instance_of Decidim::Bih::Infobip::Client, Decidim::Bih.phone_auth_delivery_client
    end

    test "production rejects a selected demo adapter before it can send" do
      Decidim::Bih.phone_auth_demo_client_factory = -> { raise "Must not instantiate" }
      environment("MI_INSTALL_PROFILE" => "production", "MI_LOCAL_HTTP" => "true", "MI_DEMO_PHONE_CAPTURE" => "true") do
        assert_raises(ArgumentError) { Decidim::Bih.phone_auth_delivery_client }
      end
      assert_empty ActionMailer::Base.deliveries
    end

    test "demo phone capture requires separate explicit opt in" do
      Decidim::Bih.phone_auth_demo_client_factory = -> { MiDemoPhoneCapture.new }
      environment("MI_INSTALL_PROFILE" => "demo", "MI_LOCAL_HTTP" => "true", "MI_DEMO_PHONE_CAPTURE" => "false") do
        assert_raises(ArgumentError) { Decidim::Bih.phone_auth_delivery_client }
      end
    end

    test "adapter must identify its simulated status" do
      Decidim::Bih.phone_auth_demo_client_factory = -> { Object.new }
      demo_environment do
        assert_raises(ArgumentError) { Decidim::Bih.phone_auth_delivery_client }
      end
    end

    test "local captured message is labelled simulated and leaves provider readiness untouched" do
      Decidim::Bih.phone_auth_demo_client_factory = -> { MiDemoPhoneCapture.new }
      ready_before = Decidim::Bih::Infobip::Client.new.configured?
      demo_environment do
        transport = Decidim::Bih.phone_auth_delivery_client
        result = transport.send_phone_message(to: "+15555550101", text: "Synthetic code 654321; https://127.0.0.1/v/synthetic-proof")
        assert_equal "simulated", result.fetch("delivery_mode")
        assert_equal false, result.fetch("provider_ready")
        mail = ActionMailer::Base.deliveries.last
        assert_includes mail.subject, "SIMULATED"
        assert_includes mail.body.to_s, "http://127.0.0.1:3200/v/synthetic-proof"
      end
      assert_equal ready_before, Decidim::Bih::Infobip::Client.new.configured?
    end

    test "another recipient is refused without provider fallback" do
      demo_environment do
        assert_raises(Decidim::Bih::Infobip::Error) do
          MiDemoPhoneCapture.new.send_phone_message(to: "+15555550102", text: "Synthetic example")
        end
      end
      assert_empty ActionMailer::Base.deliveries
    end

    test "queued authentication messages use the same scoped local capture adapter" do
      Decidim::Bih.phone_auth_demo_client_factory = -> { MiDemoPhoneCapture.new }
      demo_environment do
        Decidim::Bih::Infobip::SendPhoneMessageJob.perform_now(to: "+15555550101", text: "Synthetic message", expires_at: 5.minutes.from_now)
      end
      assert_equal 1, ActionMailer::Base.deliveries.size
      assert_includes ActionMailer::Base.deliveries.last.subject, "SIMULATED"
    end

    test "production initializer refuses legacy demo switches" do
      environment("MI_INSTALL_PROFILE" => "production", "MI_LOCAL_HTTP" => "true") do
        error = assert_raises(RuntimeError) { load Rails.root.join("config/initializers/mi_installation_profile.rb") }
        assert_match(/refuses demo/, error.message)
      end
    end

    private

    def demo_environment(&)
      environment({ "MI_INSTALL_PROFILE" => "demo", "MI_LOCAL_HTTP" => "true", "MI_DEMO_PHONE_CAPTURE" => "true", "MI_WEB_PORT" => "3200" }, &)
    end

    def environment(values)
      before = values.to_h { |key, _| [key, ENV.fetch(key, nil)] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      before.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
  end
end
