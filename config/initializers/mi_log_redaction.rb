# frozen_string_literal: true

# Keep URL-borne credentials out of the Rails request log.
#
# Rails::Rack::Logger opens every request with one line:
#
#   Started POST "/v/<24 random bytes, base64>" for 1.2.3.4 at ...
#
# On a passwordless platform that token IS the credential: until it is consumed
# or expires, anyone who can read the log can sign in as that citizen. nginx
# access logging is switched off for these paths, but Rails writes its own log,
# to its own file, which is kept longer and read by more people than nginx's —
# so the path segment has to be redacted at the source.
#
# Query parameters are NOT the gap: config/initializers/filter_parameter_logging.rb
# registers :token (which partial-matches `pending_token`, the credential that
# resumes a one-step registration), and request.filtered_path applies that list
# to this same "Started" line. Only the PATH segment is uncovered, and
# filter_parameters cannot reach a path — which is what this file is for.
#
# Prepended rather than swapped into the middleware stack: one method changes,
# and there is no second copy of Rails' own middleware wiring (and its log_tags
# argument) to keep in step through upgrades.
#
# The module keeps its historical name; it now redacts every credential this
# platform puts in a path segment, not the magic link alone.
module MiMagicLinkLogRedaction
  # The short host route /v/:token and the engine's mounted /biceriseno/v/:token
  # are the same credential on two paths (see CLAUDE.md), and the mount segment
  # is configurable through DECIDIM_BIH_PUBLIC_MOUNT_PATH — so one optional
  # leading segment is matched rather than the Bijeljina spelling only.
  MAGIC_LINK_PATH = %r{\A(/(?:[^/?]+/)?v/)[^/?]+}

  # Isporuka D: the "prove this address" link, /biceriseno/potvrdi-email/:token.
  # It proves an ADDRESS rather than opening a session, so it is a weaker
  # credential than the magic link — but it is still a credential that arrives
  # by e-mail, and a log full of them is a log full of ways to mark somebody
  # else's address proven. Same mount-agnostic shape as above; the bare POST
  # /biceriseno/potvrdi-email (no token) has nothing after the segment and is
  # left alone.
  EMAIL_CONFIRMATION_PATH = %r{\A(/(?:[^/?]+/)?potvrdi-email/)[^/?]+}

  TOKEN_PATH_PATTERNS = [MAGIC_LINK_PATH, EMAIL_CONFIRMATION_PATH].freeze
  REDACTED = "[FILTERED]"

  # The path is the first (and only) quoted run in Rails' "Started" line; the
  # method, the IP and the timestamp are not quoted. Rewriting that run rather
  # than rebuilding the message keeps this working if Rails changes the format.
  def self.redact_message(message)
    message.sub(/"([^"]*)"/) { %("#{redact_path(Regexp.last_match(1))}") }
  end

  def self.redact_path(path)
    TOKEN_PATH_PATTERNS.reduce(path) do |redacted, pattern|
      redacted.sub(pattern) { "#{Regexp.last_match(1)}#{REDACTED}" }
    end
  end

  private

  def started_request_message(request)
    MiMagicLinkLogRedaction.redact_message(super)
  end
end

Rails::Rack::Logger.prepend(MiMagicLinkLogRedaction)
