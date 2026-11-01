# frozen_string_literal: true

# Rate-limiting for mounted public write endpoints that either fan out to
# downstream services or mutate public state. Most are anonymous; community
# project/need/offer writes are authenticated but still bounded against churn:
#
#   POST /biceriseno/prijave         — anonymous "Bice riseno" problem-report intake
#   POST /biceriseno/viber-bm/webhook — Infobip Viber Business Messages intake
#   POST /biceriseno/viber/webhook   — Infobip Viber Bot inbound webhook (dormant)
#   POST /biceriseno/{whatsapp,messenger,instagram}/webhook — external chat intake
#   POST /biceriseno/chat            — public "MI bot" web-chat widget endpoint
#   POST /biceriseno/chat/feedback   — public MI bot answer feedback
#   POST /biceriseno/komsiluk/suggest — authenticated address geocoding helper
#   POST /biceriseno/komsiluk-board  — public neighborhood board write endpoint
#   POST/PATCH /biceriseno/{projekti,volontiranje}/... — community contributions
#   POST /biceriseno/pozivnica/potvrdi — launch invitation attendance confirmation
#   POST /biceriseno/prijava/kod — passwordless login-code verification
#   POST /users                      — citizen sign-up (phone-first front door)
#   POST /registracija               — one-step registration, the same front door
#   POST /sms/authorizations         — Decidim's SMS verification form (paid send)
#   POST/DELETE /biceriseno/verifikacija/telefon[/kod|/ponovo] — phone verification page
#   GET  /biceriseno/verifikacija/telefon/status — verification status poll
#   POST/DELETE /registracija/potvrda[/kod|/ponovo|/pocni-ispocetka] — the same
#                                      four moves on the one-step pending page
#   POST /registracija/potvrda/status — pending-page status poll (a POST: it can
#                                      sign the waiting browser in — R-D4)
#   POST /biceriseno/potvrdi-email   — "prove this address" (paid outbound mail)
#   GET/POST /registracija/drustvene-mreze — social registration handoff claim
#   POST /admin/bih/pozivnice/provjera — operator entry-code check-in at the door
#
# Discriminator choice is not cosmetic here. The launch venue (17.9., ~310
# citizens) puts the whole room behind ONE egress IP, so every rule a signed-in
# citizen hits during registration is keyed per SESSION, never per IP; the
# anonymous sign-up rule stays per IP but is sized for a crowd (200/15 min).
# MI_RACK_ATTACK_SAFELIST_IPS (below) is the escape hatch for the event itself:
# set it to the venue's egress IP for the evening and EMPTY IT AFTERWARDS. It
# relaxes IP-KEYED LIMITS ONLY — per-phone, per-session and provider-webhook
# rules keep counting a listed address exactly as they would any other. That
# includes Decidim core's own platform-wide "requests by ip" ceiling, which this
# file re-registers at the bottom for exactly that reason; core's limit and
# period (DECIDIM_THROTTLING_MAX_REQUESTS / _PERIOD) are read, never copied or
# changed.
#
# Decidim core already inserts the Rack::Attack middleware in production and test
# (its own config/initializers/rack_attack.rb, guarded by prod||test). This file
# configures the throttles (which apply to that single global middleware) and
# only inserts the middleware ourselves in the environments Decidim doesn't
# (e.g. development) — see the bottom of this file — so it is in the stack
# exactly once everywhere.
require "digest"
require "ipaddr"
require "rack/attack"
require "decidim/bih/locale_path"

# Back the counters with Redis so limits hold across processes/workers. The
# shared resolver keeps the local default outside tests and fails closed under
# test (an explicit, non-production REDIS_URL is required; see
# Decidim::Bih::RedisEndpoint). Tests that need determinism swap in an
# in-memory store (see test/integration/rack_attack_test.rb).
Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(
  url: Decidim::Bih::RedisEndpoint.url
)

# Never throttle local traffic (health checks, console-driven requests, the
# dev box itself). Safelists win over throttles in rack-attack.
Rack::Attack.safelist("allow localhost") do |request|
  ["127.0.0.1", "::1"].include?(request.ip)
end

# Venue relaxation for the launch event. MI_RACK_ATTACK_SAFELIST_IPS is a
# comma-separated list of exact IPs or CIDRs, parsed ONCE here at boot (never
# per request), empty by default.
#
# Why it exists: on 17.9. hundreds of citizens register from one room over one
# NAT, and the anonymous per-IP ceilings below — sign-up above all — are sized
# for a crowd but not for an unbounded one. Listing that egress IP for the
# evening lifts the ceiling for the room.
#
# Deliberately NOT a Rack::Attack.safelist. A safelist short-circuits ahead of
# every rule, so listing the venue would also switch off the per-phone budget
# that stops one number being billed over and over, the per-session budgets on
# the verification page, and the provider-webhook ceilings — none of which a
# crowded room has anything to do with. Instead the list is consulted by
# MiRackAttack.ip_key, which is the discriminator of the IP-keyed rules and
# only those: a listed address is relaxed exactly where sharing a NAT is the
# problem, and counted normally everywhere else.
#
# A malformed entry is skipped with a warning rather than taking boot down: a
# typo in .env must not cost the site.
module MiRackAttackSafelist
  module_function

  # Split, parse and freeze one comma-separated MI_RACK_ATTACK_SAFELIST_IPS
  # value. A separate method only so the suite can prove the parsing rules
  # (exact IPv4, CIDR, IPv6, and a malformed entry that is warned about and
  # skipped) without re-booting the process for each case; production calls it
  # exactly once, below.
  def parse(value)
    value.to_s.split(",").filter_map do |entry|
      candidate = entry.strip
      next if candidate.empty?

      begin
        IPAddr.new(candidate)
      rescue StandardError
        Rails.logger.warn("[rack_attack] MI_RACK_ATTACK_SAFELIST_IPS entry #{candidate.inspect} is not an IP or CIDR — ignored.")
        nil
      end
    end.freeze
  end

  ENTRIES = parse(ENV.fetch("MI_RACK_ATTACK_SAFELIST_IPS", ""))

  # Read through a method, not the constant: ENTRIES is frozen at boot (that is
  # the point of "read once"), and the suite still has to prove both the listed
  # and the unlisted case.
  def entries
    ENTRIES
  end

  def match?(ip)
    return false if ip.blank? || entries.empty?

    address = IPAddr.new(ip.to_s)
    entries.any? { |entry| entry.include?(address) }
  rescue StandardError
    false
  end
end

module MiRackAttack
  # Share each budget across localized and legacy paths; locale switching
  # must not grant another paid-message or registration allowance.
  def self.path(request)
    Decidim::Bih::LocalePath.strip(request.path)
  end

  # The verification page polls this every five seconds while the citizen taps
  # the link on their phone. It has its own per-session ceiling
  # (bih/phone-verification-status/session), and it is the one endpoint a
  # perfectly legitimate visitor hits twelve times a minute — so it is excluded
  # from the platform-wide per-IP ceiling at the bottom of this file, or a small
  # office or cafe NAT would be eaten by the poll alone. It has a per-IP ceiling
  # of its own instead (bih/phone-verification-status/ip): an exemption with
  # nothing behind it is an amplifier.
  PHONE_VERIFICATION_STATUS_PATH = "/biceriseno/verifikacija/telefon/status"

  # The exact path, plus the .json the poller actually requests — NOT
  # start_with?. A prefix match also accepted /status-anything, which handed
  # anyone a way to opt an arbitrary URL out of the platform-wide per-IP
  # ceiling just by naming it with that prefix. An exemption has to be exact.
  PHONE_VERIFICATION_STATUS_PATTERN = /\A#{Regexp.escape(PHONE_VERIFICATION_STATUS_PATH)}(?:\.json)?\z/

  # Delivery D's one-step registration answers at TWO bases: the root path this
  # host owns and the engine mount, which keeps answering for the same
  # controller and the same paid messages. Both are metered, by the same rules
  # — a rule covering one of them would leave the other a free second ceiling.
  #
  # Two sources for that base, because they can disagree and each is
  # authoritative about something different:
  #
  # config/routes.rb, which is the ground truth for what this host actually
  # ANSWERS. Typed here rather than derived, and listed unconditionally: if the
  # guarded assignment in decidim_bih_registration.rb ever skipped (an engine
  # predating the setting), the engine would report the mounted base while
  # these routes went on serving /registracija — unmetered.
  HOST_REGISTRATION_BASE_PATH = "/registracija"

  # ...and Decidim::Bih, which is the ground truth for what the engine BUILDS
  # its URLs from, and therefore where a citizen actually lands. Read rather
  # than copied, so a host that moves the base moves these rules with it, and
  # loaded after decidim_bih_registration.rb ("d" sorts before "r").
  #
  # Guarded for the same reason DecidimBihSettings.apply exists (see
  # config/initializers/decidim_bih_apply_setting.rb): the engine is a separate
  # repository loaded through a Bundler local override, so a host can boot for
  # a few minutes against a tree that predates #registration_path_for — and an
  # unguarded call here is a NoMethodError at BOOT, i.e. a total outage, not a
  # missing throttle.
  REGISTRATION_BASE_PATH =
    (Decidim::Bih.registration_path_for if Decidim::Bih.respond_to?(:registration_path_for)) ||
    HOST_REGISTRATION_BASE_PATH

  # uniq: on a correctly configured host the first two collapse into one, and
  # this list is the two bases above — the root path and the engine mount.
  REGISTRATION_PENDING_PATHS = [
    "#{HOST_REGISTRATION_BASE_PATH}/potvrda",
    "#{REGISTRATION_BASE_PATH}/potvrda",
    Decidim::Bih.public_path("registracija/potvrda")
  ].uniq.freeze

  # Same exactness rule as delivery A's poll: both spellings listed, never a
  # prefix match, so nothing a later route hangs below ".../status" inherits
  # the platform-wide exemption by accident.
  REGISTRATION_STATUS_PATHS =
    REGISTRATION_PENDING_PATHS.flat_map { |path| ["#{path}/status", "#{path}/status.json"] }.freeze

  module_function

  # One poll, two verbs, one budget. Delivery A's signed-in page asks with a
  # GET; the one-step pending page asks with a POST, because that request can
  # sign the waiting browser in and no state-changing endpoint may be reachable
  # as a GET (R-D4). Pairing each path with its own verb is deliberate: a GET on
  # the registration path is not the poll and must not inherit its exemption
  # from the platform-wide per-IP ceiling.
  def status_poll?(request)
    if request.get?
      MiRackAttack.path(request).match?(PHONE_VERIFICATION_STATUS_PATTERN)
    elsif request.post?
      REGISTRATION_STATUS_PATHS.include?(MiRackAttack.path(request))
    else
      false
    end
  end

  # These exact launch routes have their own crowd-sized IP ceilings below.
  # A room sharing Wi-Fi must not spend the generic 100/minute budget on
  # twenty result refreshes per person. Other verbs and lookalike paths stay
  # under the generic rule.
  def launch_link?(request)
    (request.get? || request.post?) && MiRackAttack.path(request).match?(%r{\A/v/event-[A-Za-z0-9_-]{32}\z})
  end

  def launch_poll_read?(request)
    request.get? && MiRackAttack.path(request).match?(%r{\A/lansiranje/anketa(?:/rezultati)?(?:\.json)?\z})
  end

  def launch_map_read?(request)
    request.get? && MiRackAttack.path(request).match?(%r{\A/biceriseno/mapa(?:\.json)?\z})
  end

  def launch_vote?(request)
    request.post? && MiRackAttack.path(request).match?(%r{\A/lansiranje/anketa/glas(?:\.json)?\z})
  end

  def launch_route?(request)
    launch_link?(request) || launch_poll_read?(request) || launch_map_read?(request) || launch_vote?(request)
  end

  # The discriminator for every IP-keyed rule in this file. Returning nil makes
  # Rack::Attack skip the rule entirely (Throttle#matched_by? bails on a falsy
  # discriminator), which is how the venue address is relaxed without a
  # safelist and without touching any other rule's key.
  #
  # Provider webhooks keep raw request.ip on purpose: their ceilings exist to
  # bound a source that claims to be Infobip, and "the venue is in the room"
  # is not a reason to trust that source more.
  def ip_key(request)
    ip = request.ip
    return nil if MiRackAttackSafelist.match?(ip)

    ip
  end

  # request.params parses the query string AND the request body. A truncated or
  # otherwise malformed multipart body makes that raise INSIDE the middleware,
  # which is a 500 on the very endpoint the rule exists to protect — and one an
  # attacker can trigger at will. A body we cannot parse cannot carry a phone
  # number either, so an unparseable request simply carries no phone key.
  def params(request)
    request.params
  rescue StandardError => e
    # The class name and nothing else. The exception message from a body parser
    # can quote the body it choked on, and the body of a request to these
    # endpoints is a phone number.
    Rails.logger.warn("[rack-attack] request params unreadable: #{e.class.name}")
    {}
  end

  # Engine-skew guard for the per-phone rules.
  #
  # Decidim::Bih::Throttling.phone_key normalises and SALTS with the application
  # secret. The discriminator becomes a Rack::Attack cache key, and a bare digest
  # of a phone number is one lookup table away from being the number itself — the
  # whole BiH mobile space is a few million candidates. So the engine helper is
  # what we call, never a reimplementation: the engine's rules and ours then
  # count the same citizen under the same key.
  #
  # The engine is a separate repository loaded through a Bundler local override,
  # so a host that boots against an engine tree without Throttling would raise
  # NameError inside the middleware — again a 500 on the endpoint rather than a
  # skipped throttle. The fallback keeps the rule counting under a bare
  # normalised number for the minutes such a skew lasts. It is unsalted, which
  # is why it is a fallback and not the design.
  #
  # Resolved PER REQUEST, not memoised at boot: the engine is reloadable, so a
  # constant that was absent when this file loaded can be present on the next
  # request (and vice versa).
  def phone_key(raw)
    # inherit: false. Module#const_defined? otherwise also searches Object, so a
    # top-level ::Throttling — anyone's, from any gem — would answer true here
    # and send us to Decidim::Bih::Throttling, which is exactly the constant we
    # just failed to find.
    return Decidim::Bih::Throttling.phone_key(raw) if Decidim::Bih.const_defined?(:Throttling, false)

    raw.to_s.gsub(/[^+0-9]/, "").presence
  end
end

# ~10 intake submissions / minute / IP. A genuine human files one report at a
# time; anything above this from a single IP is a script.
Rack::Attack.throttle("bih/reports.create/ip", limit: 10, period: 60) do |request|
  MiRackAttack.ip_key(request) if request.post? && MiRackAttack.path(request) == "/biceriseno/prijave"
end

# The duplicate-detection "me too" corroboration (+1 on an existing report) is a
# public mutating endpoint at /biceriseno/prijave/:reference/potvrdi. It has no
# email/LLM side effects (counter bump only), but bound it so a script can't
# inflate a report's corroboration count.
Rack::Attack.throttle("bih/reports.corroborate/ip", limit: 15, period: 60) do |request|
  MiRackAttack.ip_key(request) if request.post? && MiRackAttack.path(request).match?(%r{\A/biceriseno/prijave/[^/]+/potvrdi\z})
end

# ~60 webhook deliveries / minute / IP. Higher because Infobip can legitimately
# batch inbound Viber messages, but still bounded against abuse.
#
# The three webhook rules below keep raw request.ip rather than
# MiRackAttack.ip_key: they bound a source claiming to be a provider, and the
# venue list has no business relaxing that. Same for the per-phone and
# per-session rules further down.
Rack::Attack.throttle("bih/viber.webhook/ip", limit: 60, period: 60) do |request|
  request.ip if request.post? && MiRackAttack.path(request) == "/biceriseno/viber/webhook"
end

# Viber Business Messages is the live MIlica transport and carries the bulk of
# inbound conversation, so it gets its own budget rather than competing with the
# guidance-only channels below.
Rack::Attack.throttle("bih/viber-bm.webhook/ip", limit: 120, period: 60) do |request|
  request.ip if request.post? && MiRackAttack.path(request) == "/biceriseno/viber-bm/webhook"
end

# WhatsApp, Messenger and Instagram share one 60/minute source-IP budget. A
# provider may post batches, while one abusive source cannot multiply its limit
# by rotating among the three endpoints.
infobip_chat_webhook_path = %r{\A/biceriseno/(?:whatsapp|messenger|instagram)/webhook\z}
Rack::Attack.throttle("bih/infobip-chat.webhook/ip", limit: 60, period: 60) do |request|
  request.ip if request.post? && MiRackAttack.path(request).match?(infobip_chat_webhook_path)
end

# ~30 chat messages / minute / IP. A real visitor sends a handful of questions;
# this leaves comfortable headroom for a lively conversation while still capping
# a script that would otherwise hammer the (paid) LLM classifier behind the bot.
Rack::Attack.throttle("bih/chat.create/ip", limit: 30, period: 60) do |request|
  MiRackAttack.ip_key(request) if request.post? && MiRackAttack.path(request) == "/biceriseno/chat"
end

# ~60 answer feedback clicks / minute / IP. This endpoint does not call the
# brain and stores metadata only, but it is still a public write path.
Rack::Attack.throttle("bih/chat.feedback/ip", limit: 60, period: 60) do |request|
  MiRackAttack.ip_key(request) if request.post? && MiRackAttack.path(request) == "/biceriseno/chat/feedback"
end

# The session ID, or nil when this request carries no session.
#
# NOT the session COOKIE value, which is what this used to read. With the
# default CookieStore that value is AES-GCM ciphertext, rewritten on nearly
# every request that touches the session (any flash will do), so each request
# landed under its own counter and every per-session throttle below could count
# at most 1 and never fire. The id behind the cookie is stable for the life of
# the session.
#
# Reading it neither loads nor creates a session: ActionDispatch's Session#id
# extracts the id from the request and returns nil when there is none, so this
# is safe to call for anonymous traffic. respond_to? because Rack hands us a
# plain Hash when no session middleware ran.
public_session_id = lambda do |request|
  session = request.session
  session.respond_to?(:id) ? session.id.to_s.presence : nil
end

# Per-session budget for the surfaces a SIGNED-IN citizen hits. Per-IP ceilings
# cannot be used there: the launch venue puts the whole room behind one NAT, and
# a shared egress IP would lock everyone out of the very step they came to do.
# The session is the closest thing to "one citizen" Rack::Attack can see this
# early in the stack.
#
# Call it ONLY from inside a matching block — reaching for request.session on
# every request would mint a session cookie for anonymous traffic. The raw id is
# digested before it becomes a cache key, so it never reaches the Rack::Attack
# store or its logs, and a request carrying no session at all falls back to the
# IP so the rule still counts something.
public_session_discriminator = lambda do |request|
  id = public_session_id.call(request)
  # request.ip, not MiRackAttack.ip_key: these are per-session rules and the
  # venue list must never reach them. A sessionless request from a listed
  # address still gets counted.
  id.blank? ? "ip:#{request.ip}" : "s:#{Digest::SHA256.hexdigest(id)[0, 32]}"
end

# Project submissions, non-cash needs, and contribution-offer transitions share
# one authenticated write budget: 10/min/IP and 60/hour/session. The predicate
# pairs each route with its actual verb so reads and similarly named paths are
# never counted.
community_projects_path = "/biceriseno/projekti"
community_project_submission_path = %r{\A#{Regexp.escape(community_projects_path)}/prijave/[^/]+\z}
contribution_needs_path = "/biceriseno/volontiranje/potrebe"
contribution_need_cancel_path = %r{\A#{Regexp.escape(contribution_needs_path)}/[^/]+/otkazi\z}
contribution_offer_create_path = %r{\A#{Regexp.escape(contribution_needs_path)}/[^/]+/ponude\z}
contribution_offers_path = "/biceriseno/volontiranje/ponude"
contribution_offer_action_path = %r{\A#{Regexp.escape(contribution_offers_path)}/[^/]+/(?:prihvati|odbij|povuci|isporuceno|potvrdi)\z}
community_contribution_write_path = lambda do |request|
  (request.post? && MiRackAttack.path(request) == community_projects_path) ||
    (request.request_method == "PATCH" && MiRackAttack.path(request).match?(community_project_submission_path)) ||
    (request.post? && MiRackAttack.path(request) == contribution_needs_path) ||
    (request.post? && MiRackAttack.path(request).match?(contribution_need_cancel_path)) ||
    (request.post? && MiRackAttack.path(request).match?(contribution_offer_create_path)) ||
    (request.post? && MiRackAttack.path(request).match?(contribution_offer_action_path))
end

Rack::Attack.throttle("bih/community-contributions.write/ip", limit: 10, period: 60) do |request|
  MiRackAttack.ip_key(request) if community_contribution_write_path.call(request)
end

Rack::Attack.throttle("bih/community-contributions.write/session", limit: 60, period: 3600) do |request|
  public_session_discriminator.call(request) if community_contribution_write_path.call(request)
end

organization_write_path = lambda do |request|
  path = MiRackAttack.path(request)
  membership_action = %r{\A/biceriseno/organizacija/clanstvo/[^/]+/(?:prihvati|odbij|napusti)\z}
  organization_action = %r{\A/biceriseno/organizacija/[^/]+/(?:regrant|potrosnja|obavjestenja|clanovi(?:/[^/]+)?)\z}
  organization_profile = %r{\A/biceriseno/organizacije/[^/]+\z}

  (request.post? && path == "/biceriseno/organizacije") ||
    (request.request_method == "PATCH" && path.match?(organization_profile)) ||
    (request.post? && path.match?(organization_action)) ||
    (%w(PATCH DELETE).include?(request.request_method) && path.match?(membership_action))
end

Rack::Attack.throttle("bih/organizations.write/ip", limit: 10, period: 60) do |request|
  MiRackAttack.ip_key(request) if organization_write_path.call(request)
end

Rack::Attack.throttle("bih/organizations.write/session", limit: 30, period: 3600) do |request|
  public_session_discriminator.call(request) if organization_write_path.call(request)
end

# Address suggestion calls the configured geocoder, so it is capped even though
# the controller also requires a signed-in citizen and discards the address.
Rack::Attack.throttle("bih/komsiluk.suggest/ip", limit: 20, period: 60) do |request|
  MiRackAttack.ip_key(request) if request.post? && MiRackAttack.path(request) == "/biceriseno/komsiluk/suggest"
end

Rack::Attack.throttle("bih/komsiluk.suggest/session", limit: 60, period: 3600) do |request|
  public_session_discriminator.call(request) if request.post? && MiRackAttack.path(request) == "/biceriseno/komsiluk/suggest"
end

# Komšiluk board write paths: 5/min per IP, 10/hour per session.
# Mirrors the report-intake + phone-login patterns.
komsiluk_board_write_path = lambda do |request|
  path = MiRackAttack.path(request)

  (request.post? && path == "/biceriseno/komsiluk-board") ||
    (request.post? && path.match?(%r{\A/biceriseno/komsiluk-board/[^/]+/(?:prijavi|help)\z})) ||
    (%w(PATCH PUT).include?(request.request_method) && path.match?(%r{\A/biceriseno/komsiluk-board/[^/]+(?:/(?:zatvori|resolve))?\z}))
end

Rack::Attack.throttle("bih/komsiluk-board.write/ip", limit: 5, period: 60) do |request|
  MiRackAttack.ip_key(request) if komsiluk_board_write_path.call(request)
end

Rack::Attack.throttle("bih/komsiluk-board.write/session", limit: 10, period: 3600) do |request|
  public_session_discriminator.call(request) if komsiluk_board_write_path.call(request)
end

# Magic-link consume attempts: tokens are 24-byte random, but cap guessing anyway.
# The engine mounts its confirm action at /biceriseno/v/:token; the host app also
# has /v/:token — both must be covered.
Rack::Attack.throttle("bih/magic-link", limit: 10, period: 1.minute) do |req|
  MiRackAttack.ip_key(req) if req.post? && MiRackAttack.path(req).match?(%r{\A/(biceriseno/)?v/}) && !MiRackAttack.path(req).match?(%r{\A/v/event-[A-Za-z0-9_-]{32}\z})
end

# Event attendees share venue Wi-Fi. Meter the personal credential, not the
# hall's single IP; keep a separate generous IP ceiling for invalid guessing.
Rack::Attack.throttle("mi/launch-link/token", limit: 10, period: 1.minute) do |req|
  Digest::SHA256.hexdigest(MiRackAttack.path(req)) if req.post? && MiRackAttack.path(req).match?(%r{\A/v/event-[A-Za-z0-9_-]{32}\z})
end
Rack::Attack.throttle("mi/launch-link/ip", limit: 2000, period: 1.minute) do |req|
  MiRackAttack.ip_key(req) if MiRackAttack.launch_link?(req)
end
Rack::Attack.throttle("mi/launch-poll/session", limit: 10, period: 1.minute) do |req|
  public_session_discriminator.call(req) if MiRackAttack.launch_vote?(req)
end

# 500 viewers at the three-second refresh cadence consume 10,000/minute.
# Keep headroom for initial loads, while bounding both sessions and the room.
Rack::Attack.throttle("mi/launch-poll-read/ip", limit: 15_000, period: 1.minute) do |req|
  MiRackAttack.ip_key(req) if MiRackAttack.launch_poll_read?(req)
end
Rack::Attack.throttle("mi/launch-poll-read/session", limit: 120, period: 1.minute) do |req|
  next unless MiRackAttack.launch_poll_read?(req)

  id = public_session_id.call(req)
  Digest::SHA256.hexdigest(id) if id.present?
end
Rack::Attack.throttle("mi/launch-map/ip", limit: 2000, period: 1.minute) do |req|
  MiRackAttack.ip_key(req) if MiRackAttack.launch_map_read?(req)
end
Rack::Attack.throttle("mi/launch-vote/ip", limit: 2000, period: 1.minute) do |req|
  MiRackAttack.ip_key(req) if MiRackAttack.launch_vote?(req)
end

# Passwordless login-link requests: per IP and per phone.
# The engine mounts the form at /biceriseno/prijava (POST).
Rack::Attack.throttle("bih/phone-login/ip", limit: 5, period: 15.minutes) do |req|
  MiRackAttack.ip_key(req) if req.post? && MiRackAttack.path(req) == "/biceriseno/prijava"
end

# The challenge itself also enforces five attempts per user in Redis. This
# outer IP budget limits distributed session churn without reading the code.
Rack::Attack.throttle("bih/phone-login-code/ip", limit: 10, period: 1.minute) do |req|
  MiRackAttack.ip_key(req) if req.post? && MiRackAttack.path(req) == "/biceriseno/prijava/kod"
end

# Both verbs, one budget. The GET renders the handoff claim page and already
# does the Redis peek for the pending handoff, so it costs what the POST costs;
# counting only the POST would leave the expensive half unbounded.
Rack::Attack.throttle("bih/social-registration-handoff/ip", limit: 10, period: 1.minute) do |req|
  MiRackAttack.ip_key(req) if (req.get? || req.post?) && MiRackAttack.path(req) == "/registracija/drustvene-mreze"
end

# Per-phone budget for the passwordless login link. MiRackAttack.phone_key calls
# the engine's salted helper (see its comment above) and reads the body through
# MiRackAttack.params so a malformed one cannot 500 the endpoint.
# Deploy order still matters: the engine ships before the host (see
# docs/DEPLOYMENT.md) — the guard keeps a skew counting, it does not make skew
# acceptable.
Rack::Attack.throttle("bih/phone-login/phone", limit: 3, period: 15.minutes) do |req|
  MiRackAttack.phone_key(MiRackAttack.params(req)["phone"]) if req.post? && MiRackAttack.path(req) == "/biceriseno/prijava"
end

# Sign-up is the front door of phone-first registration: one POST creates a
# usable account and puts the citizen one click from a paid message. Both doors
# into that room count here — Decidim's own /users and delivery D's one-step
# form — because a flood through either buys nothing without a verified phone
# behind each account, and two budgets would only mean the attacker picks the
# fuller one. /users is a Decidim core route (outside the engine mount) and
# both are ANONYMOUS, so there is no session to key on and this one has to stay
# per IP. The ceiling is therefore set for the worst LEGITIMATE case rather
# than the typical one: a launch venue where hundreds of citizens register over
# one NAT within the hour.
registration_create_paths = [
  "/users",
  MiRackAttack::HOST_REGISTRATION_BASE_PATH,
  MiRackAttack::REGISTRATION_BASE_PATH,
  Decidim::Bih.public_path("registracija")
].uniq.freeze

Rack::Attack.throttle("bih/registration-create/ip", limit: 200, period: 15.minutes) do |req|
  MiRackAttack.ip_key(req) if req.post? && registration_create_paths.include?(MiRackAttack.path(req))
end

# The ceiling above is set for the worst LEGITIMATE case — a launch venue on
# one NAT — and the venue safelist relaxes it further, so it bounds nothing a
# script does from a handful of addresses. Each POST spends a real message on
# whatever number was typed, which need not be the typist's, and the form's
# "already verified" answer is distinct enough to enumerate with. This budget
# keys on the NUMBER, so neither rotating IPs nor the venue relaxation moves
# it. Decidim's own /users posts the same field name.
Rack::Attack.throttle("bih/registration-create/phone", limit: 5, period: 15.minutes) do |req|
  MiRackAttack.phone_key(MiRackAttack.params(req).dig("user", "mobile_phone_number")) if req.post? && registration_create_paths.include?(MiRackAttack.path(req))
end

# "Potvrdi e-mail" from Moj nalog. Every request spends a real e-mail to an
# address the platform has NOT proven, so this endpoint is a way to point the
# platform's own outbound mail at a stranger's inbox. The controller already
# refuses a second request inside 20 minutes; this bounds how fast one session
# can walk around that by changing the address in between. Per session for the
# same reason as the phone surfaces: the venue puts the whole room on one NAT.
email_confirmation_request_path = Decidim::Bih.public_path("potvrdi-email")

Rack::Attack.throttle("bih/email-confirmation-request/session", limit: 3, period: 15.minutes) do |req|
  public_session_discriminator.call(req) if req.post? && MiRackAttack.path(req) == email_confirmation_request_path
end

# Decidim's stock SMS verification form. Every submission spends a real Infobip
# message, so it is metered twice: once per session and, more tightly, once per
# number. The number is the thing that actually costs money, and it is the one
# key a shared venue IP cannot dilute.
sms_authorization_phone = lambda do |req|
  # Through MiRackAttack.params: a truncated multipart body must not 500 the
  # endpoint (it just leaves this rule nothing to count).
  params = MiRackAttack.params(req)
  # Read the NESTED key first. Decidim::AttributeObject::Form.from_params does
  # `params_hash.merge(params_hash[mimicked_model_name])`, so when a request
  # carries both keys the nested mobile_phone[mobile_phone_number] WINS and is
  # the number that gets the SMS. Reading the flat key first would let one
  # crafted request per throwaway flat value bill the same victim number
  # forever, which is precisely the rule this is.
  nested = params["mobile_phone"]
  # is_a?(Hash) rather than #dig: a crafted "mobile_phone=x" makes dig raise
  # inside the middleware, i.e. hands an attacker a 500 on the very endpoint
  # this rule exists to protect.
  raw = nested["mobile_phone_number"] if nested.is_a?(Hash)
  raw = params["mobile_phone_number"] if raw.blank?
  # Normalisation (spacing and punctuation must not buy another message) and
  # salting both live in the engine helper, reached through
  # MiRackAttack.phone_key so an engine skew degrades to an unsalted key rather
  # than raising in the middleware.
  MiRackAttack.phone_key(raw)
end

Rack::Attack.throttle("bih/sms-authorization-create/session", limit: 5, period: 15.minutes) do |req|
  public_session_discriminator.call(req) if req.post? && MiRackAttack.path(req) == "/sms/authorizations"
end

Rack::Attack.throttle("bih/sms-authorization-create/phone", limit: 3, period: 15.minutes) do |req|
  sms_authorization_phone.call(req) if req.post? && MiRackAttack.path(req) == "/sms/authorizations"
end

# Phone verification page (delivery A). The names, methods, paths, limits,
# periods AND discriminators are not free choices here:
# Decidim::Bih.required_public_throttles declares this exact contract, and
# script/mi_public_throttle_contract_smoke fails the release gate when the host
# does not configure it.
#
# All four are keyed per session, never per IP. The citizen is signed in by
# this point, and the real controls live server-side anyway — the typed code is
# budgeted per authorization by Decidim::Bih::PhoneVerification::AttemptLimiter
# (5 per authorization lifetime) and a resend has a 60-second cooldown on the
# authorization row. These only bound how fast one session can hammer the
# endpoints, which is what a shared venue IP must not be punished for.
#
# Each budget covers TWO pages, on purpose. Delivery D's one-step registration
# has a pending page that does the same four things for the same citizen at
# MiRackAttack::REGISTRATION_PENDING_PATHS (the root path and the engine mount).
# A second set of budgets there would only mean a second set of paid messages
# and a second set of guesses for whoever rotates sessions.
phone_verification_path = "/biceriseno/verifikacija/telefon"
pending_paths = MiRackAttack::REGISTRATION_PENDING_PATHS

verification_code_paths = (["#{phone_verification_path}/kod"] + pending_paths.map { |p| "#{p}/kod" }).freeze
Rack::Attack.throttle("bih/phone-verification-code/session", limit: 10, period: 1.minute) do |req|
  public_session_discriminator.call(req) if req.post? && verification_code_paths.include?(MiRackAttack.path(req))
end

# A resend spends a paid Infobip message, so it is the tighter budget.
verification_resend_paths = (["#{phone_verification_path}/ponovo"] + pending_paths.map { |p| "#{p}/ponovo" }).freeze
Rack::Attack.throttle("bih/phone-verification-resend/session", limit: 5, period: 15.minutes) do |req|
  public_session_discriminator.call(req) if req.post? && verification_resend_paths.include?(MiRackAttack.path(req))
end

# "Start over" destroys a whole pending registration — the heavier version of
# the same "this number is wrong" move — so it spends the same budget rather
# than a fresh one it could be used to walk around. Hence two verbs on one
# rule: DELETE on the pages themselves, POST on the start-over action.
verification_change_paths = ([phone_verification_path] + pending_paths).freeze
registration_start_over_paths = pending_paths.map { |p| "#{p}/pocni-ispocetka" }.freeze
Rack::Attack.throttle("bih/phone-verification-change/session", limit: 5, period: 15.minutes) do |req|
  changing = (req.delete? && verification_change_paths.include?(MiRackAttack.path(req))) ||
             (req.post? && registration_start_over_paths.include?(MiRackAttack.path(req)))
  public_session_discriminator.call(req) if changing
end

# The poll is a read on delivery A's signed-in page and a POST on the
# registration one (that variant can sign the waiting browser in, so it must
# not be a GET), and either way the page asks every few seconds while the
# citizen taps the link on their phone — an unbounded endpoint is still an
# amplifier. MiRackAttack.status_poll? pairs each path with its own verb and
# lists both the .json and extension-less spellings, so the two forms share one
# budget instead of doubling it.
Rack::Attack.throttle("bih/phone-verification-status/session", limit: 30, period: 1.minute) do |req|
  public_session_discriminator.call(req) if MiRackAttack.status_poll?(req)
end

# ...and a per-IP ceiling as well, host-only (the engine's registry does not
# declare this one). The poll is exempt from the platform-wide "requests by ip"
# rule, and an exemption with no bound behind it is an amplifier: one address
# could poll this endpoint as fast as it liked by simply not carrying a session.
#
# 600/minute is deliberately generous — fifty citizens polling from one NAT at
# the page's own five-second cadence, or twenty sessions each spending their
# full per-session budget — so it never bites a real room and still stops a
# script. It goes through MiRackAttack.ip_key like every other IP-keyed rule,
# so a listed venue address is relaxed here too.
Rack::Attack.throttle("bih/phone-verification-status/ip", limit: 600, period: 1.minute) do |req|
  MiRackAttack.ip_key(req) if MiRackAttack.status_poll?(req)
end

# Potvrda dolaska na lansiranje — jedan građanin, jedan klik; sve preko toga
# je skripta.
Rack::Attack.throttle("bih/launch-invitation.confirm/ip", limit: 10, period: 60) do |request|
  MiRackAttack.ip_key(request) if request.post? && MiRackAttack.path(request) == "/biceriseno/pozivnica/potvrdi"
end

# Provjera ulaznog koda na vratima — operater skenira brzo, ali ne 120/min.
Rack::Attack.throttle("bih/launch-invitation.checkin/ip", limit: 60, period: 60) do |request|
  MiRackAttack.ip_key(request) if request.post? && MiRackAttack.path(request) == "/admin/bih/pozivnice/provjera"
end

# Decidim core's own platform-wide ceiling, re-registered here.
#
# Core does (decidim-core/config/initializers/rack_attack.rb):
#
#   Rack::Attack.throttle("requests by ip",
#                         limit: Decidim.throttling_max_requests,
#                         period: Decidim.throttling_period, &:ip)
#
# — keyed on the bare IP, 100/minute by default, and the tightest rule on the
# platform. The venue list did not reach it, so on 17.9. five citizens polling
# the verification page (twenty requests a minute each) would spend the whole
# room's budget between them and everyone else in the hall would meet a 429.
#
# Same NAME, so this REPLACES core's rule rather than adding a second one, and
# core's limit and period are read (not copied), so DECIDIM_THROTTLING_MAX_REQUESTS
# and DECIDIM_THROTTLING_PERIOD keep working and are deliberately left alone.
# Two changes: the discriminator is MiRackAttack.ip_key, so a listed venue
# address is relaxed here exactly as it is on every other IP-keyed rule; and the
# status poll is excluded, because it already has its own per-session ceiling.
#
# It has to be registered from a to_prepare block of our own. Core registers
# inside ActiveSupport::Reloader.to_prepare, which runs AFTER all initializers,
# so a plain definition here would be overwritten on the first prepare. Engine
# initializers load before the application's, so core's callback is registered
# first and ours second — and to_prepare callbacks run in registration order, so
# ours is the one left standing.
#
# Registered in EVERY environment on purpose. Core skips the rule outside
# production (`unless Rails.env.test?`), which would leave this untestable; here
# it is the same rule everywhere, and localhost stays safelisted so development
# and the rest of the suite never meet it.
ActiveSupport::Reloader.to_prepare do
  Rack::Attack.throttle(
    "requests by ip",
    limit: Decidim.throttling_max_requests,
    period: Decidim.throttling_period
  ) do |request|
    MiRackAttack.ip_key(request) unless MiRackAttack.status_poll?(request) || MiRackAttack.launch_route?(request)
  end
end

# Answer throttled requests with a small 429 instead of the default body.
Rack::Attack.throttled_responder = lambda do |_request|
  headers = { "Content-Type" => "application/json; charset=utf-8" }
  [429, headers, [%({"error":"Too many requests. Please slow down."}\n)]]
end

# Insert the middleware only where Decidim core does NOT (it adds it in
# production/test). This keeps Rack::Attack in the stack exactly once in every
# environment — verified via `bin/rails middleware`.
Rails.application.config.middleware.use Rack::Attack unless Rails.env.production? || Rails.env.test?

# Private case replies are bounded independently of initial report intake.
Rack::Attack.throttle("bih/reports.case_reply/ip", limit: 10, period: 60) do |request|
  MiRackAttack.ip_key(request) if request.post? && MiRackAttack.path(request).match?(%r{\A/biceriseno/prijave/[^/]+/status/[^/]+\z})
end
