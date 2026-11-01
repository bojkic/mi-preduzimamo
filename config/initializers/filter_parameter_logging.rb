# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn,
  # :address partial-matches the komšiluk-suggest address, geocoded_address, and any
  # postal address — these must never reach the request log (privacy contract).
  :address, :phone, :mobile_phone_number,
  # Milica accepts both a nested location object and legacy top-level point
  # fields. Rails logs parsed parameters before the chat action can redact them.
  :location, :latitude, :longitude, :lat, :lon, :lng, :accuracy,
  # A citizen can also type an address or point into the chat message itself.
  :message,
  # entry_code je jednokratni ulazni kod za lansiranje — nikad u logove.
  :entry_code, :social_handoff,
  # Infobip webhook bodies: the sender's phone number (Viber BM `from`), the
  # WhatsApp/Messenger chat id, the message text and any media URL. Rails
  # logs every parsed body at :info in the "Parameters:" line BEFORE the
  # action runs, so the controllers' own redaction cannot reach it — 2 of the
  # 15 webhook requests in production's Puma log carried a `from` and 3 a
  # `text` (review 2026-09-07, lane 3 F-1).
  :from, :to, :userId, :user_id, :contact, :text, :caption,
  :messageId, :message_id, :url, :imageUrl, :mediaUrl, :results
]

# ---------------------------------------------------------------------------
# NOTE: ActiveRecord::Base.filter_attributes is re-synced from
# config.filter_parameters in config/application.rb, not here.
#
# That re-sync is required — Rails 7.2's active_record.set_filter_attributes
# railtie snapshots config.filter_parameters before this file (and before
# engine initializers) has contributed to it, so the global ends up [] and
# ActiveRecord::LogSubscriber#filter prints raw bind values at debug level.
# A per-model `self.filter_attributes = [...]` does NOT close it: the log
# subscriber consults the global ActiveRecord::Base.inspection_filter only.
#
# This file's job is therefore just to REGISTER the keys above. Keeping a
# second after_initialize here as well would be two mechanisms for one
# guarantee, differing in whether they assign or merge — so the re-sync lives
# in exactly one place. If you are auditing redaction, read
# config/application.rb.

Rails.application.config.filter_parameters += [:case_message, :case_details, :body, :forwarding_note, :resolution_evidence, :external_submission_reference]

# Private board drafts, publication copy and confirmation capabilities.
Rails.application.config.filter_parameters += [:komsiluk_post, :photo_draft_token, :notice, :confirmation_token, :action_token, :review_note]
