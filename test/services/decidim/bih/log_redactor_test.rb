# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class LogRedactorTest < ActiveSupport::TestCase
      test "sanitizes provider messages with secrets phones and OTPs" do
        sanitized = LogRedactor.error_message(
          StandardError.new("token=secret to=38765111000 body Kod: 123456")
        )

        assert_includes sanitized, "token=[REDACTED]"
        assert_includes sanitized, "[phone:***1000]"
        assert_includes sanitized, "[OTP]"
        assert_not_includes sanitized, "secret"
        assert_not_includes sanitized, "38765111000"
        assert_not_includes sanitized, "123456"
      end

      test "redacts secrets in hash-rocket assignment form" do
        # A hash .inspect error body uses key => value; the value must be redacted.
        sanitized = LogRedactor.sanitize('{"secret" => "topsecret", :token => "deadbeef"}')

        assert_not_includes sanitized, "topsecret"
        assert_not_includes sanitized, "deadbeef"
        assert_includes sanitized, "[REDACTED]"
      end

      test "redacts secrets in key=value and key: value assignment forms" do
        equals = LogRedactor.sanitize("api_key=topsecret rest")
        # The value group stops at whitespace for unquoted values, so only the
        # first token after the operator is masked (existing behavior).
        colon = LogRedactor.sanitize("authorization: topsecret rest")

        assert_equal "api_key=[REDACTED] rest", equals
        assert_equal "authorization: [REDACTED] rest", colon
        assert_not_includes colon, "topsecret"
      end

      test "preserves URL host and path while redacting the query" do
        sanitized = LogRedactor.sanitize("see https://errors.example/status?token=secret#frag")

        assert_includes sanitized, "https://errors.example/status"
        assert_includes sanitized, "[REDACTED]"
        assert_not_includes sanitized, "token=secret"
        assert_not_includes sanitized, "frag"
      end

      test "truncate appends an ellipsis past the max" do
        assert_equal "#{"a" * 5}...", LogRedactor.truncate("a" * 10, max: 5)
        assert_equal "abc", LogRedactor.truncate("abc", max: 5)
      end

      test "mask_phone and mask_identifier keep the last four digits" do
        assert_equal "[phone:***1000]", LogRedactor.mask_phone("38765111000")
        assert_equal "[phone]", LogRedactor.mask_phone("")
        assert_equal "[phone:***1000]", LogRedactor.mask_identifier("38765111000")
        assert_equal "[identifier:***wxyz]", LogRedactor.mask_identifier("abcwxyz")
        assert_equal "[identifier]", LogRedactor.mask_identifier("")
      end

      # --- Shared-core invariant: both redactors must agree on WHAT is sensitive ---

      test "both redactors share one definition of the sensitivity patterns" do
        assert_same Decidim::Bih::Redaction::PHONE_PATTERN, LogRedactor::PHONE_PATTERN
        assert_same Decidim::Bih::Redaction::URL_PATTERN, LogRedactor::URL_PATTERN
        assert_same Decidim::Bih::Redaction::SENSITIVE_ASSIGNMENT, LogRedactor::SENSITIVE_ASSIGNMENT
        assert_same Decidim::Bih::Redaction::OTP_PATTERN, LogRedactor::OTP_PATTERN

        assert_same Decidim::Bih::Redaction::PHONE_PATTERN, SafeErrorMetadata::PHONE_PATTERN
        assert_same Decidim::Bih::Redaction::URL_PATTERN, SafeErrorMetadata::URL_PATTERN
        assert_same Decidim::Bih::Redaction::SENSITIVE_ASSIGNMENT, SafeErrorMetadata::SENSITIVE_ASSIGNMENT
        assert_same Decidim::Bih::Redaction::EMAIL_PATTERN, SafeErrorMetadata::EMAIL_PATTERN
      end

      test "both redactors flag the same input as sensitive (presentation aside)" do
        phone = "+387 65 123 456"
        url = "https://errors.example/status?token=secret"
        secret = "api_key=topsecret"

        # LogRedactor preserves operational shape; SafeErrorMetadata wipes wholesale.
        log_phone = LogRedactor.sanitize(phone)
        meta_phone = SafeErrorMetadata.sanitize_text(phone)
        assert_match(/\[phone/, log_phone)
        assert_includes meta_phone, "[phone]"
        assert_not_includes log_phone, "123 456"
        assert_not_includes meta_phone, "123 456"

        assert_not_includes LogRedactor.sanitize(url), "token=secret"
        assert_not_includes SafeErrorMetadata.sanitize_text(url), "token=secret"

        assert_not_includes LogRedactor.sanitize(secret), "topsecret"
        assert_not_includes SafeErrorMetadata.sanitize_text(secret), "topsecret"
      end
    end
  end
end
