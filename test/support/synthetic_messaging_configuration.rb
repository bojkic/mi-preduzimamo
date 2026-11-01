# frozen_string_literal: true

# Explicit fictional configuration for positive messaging examples only.
# Never included in application defaults or the global test helper.
module SyntheticMessagingConfiguration
  def with_synthetic_sms_sender(sender: "AuthoredSMS")
    owner = Decidim::Bih::Config
    present = owner.instance_variable_defined?(:@infobip)
    previous = owner.instance_variable_get(:@infobip)
    owner.instance_variable_set(:@infobip, owner.infobip.merge(sms_sender: sender))
    yield
  ensure
    if present
      owner.instance_variable_set(:@infobip, previous)
    elsif owner.instance_variable_defined?(:@infobip)
      owner.remove_instance_variable(:@infobip)
    end
  end

  def install_synthetic_intake
    @synthetic_intake_env = ENV["SISTEM48_CENTRAL_INTAKE"]
    @synthetic_intake_setting = Decidim::Bih.sistem48_central_intake
    ENV["SISTEM48_CENTRAL_INTAKE"] = "intake@community.example.invalid"
    Decidim::Bih.sistem48_central_intake = "intake@community.example.invalid"
  end

  def restore_synthetic_intake
    return unless defined?(@synthetic_intake_setting)

    @synthetic_intake_env.nil? ? ENV.delete("SISTEM48_CENTRAL_INTAKE") : ENV["SISTEM48_CENTRAL_INTAKE"] = @synthetic_intake_env
    Decidim::Bih.sistem48_central_intake = @synthetic_intake_setting
  end

  def install_synthetic_reply_mailbox
    @synthetic_bih_reply = Decidim::Bih.mailer_reply_to
    Decidim::Bih.mailer_reply_to = "reply@community.example.invalid"
  end

  def restore_synthetic_reply_mailbox
    return unless defined?(@synthetic_bih_reply)

    Decidim::Bih.mailer_reply_to = @synthetic_bih_reply
  end
end
