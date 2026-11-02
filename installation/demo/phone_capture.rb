# frozen_string_literal: true

class MiDemoPhoneCapture
  def simulated? = true

  # Available as a local transport; this does not configure Infobip.
  def configured? = true

  def send_phone_message(to:, text:, **_options)
    raise Decidim::Bih::Infobip::Error, "Only the synthetic demo recipient is allowed" unless to.to_s.delete(" ") == "+15555550101"

    port = Integer(ENV.fetch("MI_WEB_PORT", "3100"))
    raise ArgumentError, "Invalid demo port" unless (1024..65_535).cover?(port)

    captured = text.to_s.gsub(%r{https://127\.0\.0\.1(?=/)}, "http://127.0.0.1:#{port}")
    # A diagnostic transport label, intentionally identical in all demo locales.
    # rubocop:disable Rails/I18nLocaleTexts
    ActionMailer::Base.mail(from: "capture@community.example.invalid", to: "phone-capture@community.example.invalid",
                            subject: "SIMULATED LOCAL PHONE DELIVERY — no provider send", body: captured).deliver_now
    # rubocop:enable Rails/I18nLocaleTexts
    { "delivery_mode" => "simulated", "provider_ready" => false }
  end
end
