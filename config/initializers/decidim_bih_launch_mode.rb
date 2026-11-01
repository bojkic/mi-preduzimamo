# frozen_string_literal: true

# Režim lansiranja (spec §6) — while the trka komšiluka window is open, every
# surface pushes the SAME three actions (registruj se / prijavi problem / pitaj
# Milicu) and the long tail (volontiranje, donacije, uticaj) steps aside.
# DecidimApp::LaunchMode owns the "is it on?" decision; this file is only the
# wiring between that predicate and the engine's hero + navigation.
#
# NOTHING here is boot state, deliberately:
#   * Decidim.menu blocks are instance_exec'd in the view context on EVERY
#     render (Decidim::Menu#build_for), so the menu is decided per request.
#   * The hero cell reads Decidim::Bih.mi_hero_ctas / .mi_hero_stat_min per
#     render and calls the value when it responds to #call, so a Proc is
#     likewise re-evaluated per render.
# That is what lets the mode switch itself OFF at the 14.10.2026 20:00 freeze —
# and follow an operator's Setting(launch, mode) override — with no deploy and
# no restart. Do not "optimise" either side into a value computed at boot.
#
# The hero assignments are GUARDED for the same reason config/initializers/
# decidim_bih_race.rb guards its own: the host app and the decidim-bih engine
# deploy through separate git operations, and production loads the engine's
# working tree directly (CLAUDE.md). A host that ships before the engine grows
# these accessors must degrade to "no launch hero" — the engine's own default —
# rather than raise NoMethodError at boot and take the whole site down over a
# campaign toggle. The menu half has no such dependency and is unconditional.
module DecidimAppLaunchModeInitializer
  # Shown only while the mode is on. `href: :registration` is a symbol the hero
  # cell resolves through Decidim::Bih.registration_path, so the host does not
  # have to know whether registration lives at /users/sign_up or behind the
  # engine's phone-first flow.
  CTA_LABEL_PREFIX = "decidim.bih.content_blocks.mi_hero.launch_ctas"

  # Below this, a launch statistic is noise on a projector in a full hall
  # ("3 prijave" reads as failure). 0 outside the mode = show everything.
  HERO_STAT_MIN = 20

  # Remix names the launch navigation needs that NOTHING else registers —
  # neither Decidim core nor decidim-bih's own MI_ICONS list. Both ship in
  # core's remixicon.symbol.svg sprite, but Decidim::IconRegistry is a hard
  # gate: `icon "trophy-line"` on an unregistered name raises at RENDER time,
  # not at boot, so the first visitor to see the launch bottom nav would get a
  # 500. They are registered here rather than in the engine because only the
  # host's launch surfaces use them.
  LAUNCH_ICONS = {
    "trophy-line" => "Trka komšiluka standings"
  }.freeze

  module_function

  def launch_ctas
    [
      { label_key: "#{CTA_LABEL_PREFIX}.register", href: :registration, style: "primary",
        signed_in_label_key: "decidim.bih.content_blocks.mi_hero.register.signed_in_cta" },
      # All three coral: the three launch actions carry the same weight on the
      # poster, so none of them reads as the "other" option (2026-09-07).
      { label_key: "#{CTA_LABEL_PREFIX}.report", href: Decidim::Bih.public_path("prijave/new"), style: "primary" },
      { label_key: "#{CTA_LABEL_PREFIX}.ask", href: Decidim::Bih.public_path("mi-bot"), style: "primary", chat: true }
    ]
  end

  # The hero cell renders inside a request but hands the Proc no view context,
  # so fall back to the single tenant this app serves. The optional argument is
  # there so the cell CAN pass the organization it already has; a zero-arity
  # lambda would raise ArgumentError if it ever starts doing so.
  def active?(organization = nil)
    DecidimApp::LaunchMode.active?(organization || Decidim::Organization.first)
  end

  def warn_hero_accessors_missing
    return if @warned_hero_accessors_missing

    @warned_hero_accessors_missing = true
    Rails.logger.warn(
      "[decidim_bih_launch_mode] Decidim::Bih.mi_hero_ctas=/.mi_hero_stat_min= are not " \
      "defined by the loaded decidim-bih engine — skipping the launch hero. The engine " \
      "may predate them; the ordinary hero is rendered instead. The launch MENU is " \
      "unaffected."
    )
  end
end

# after_initialize, exactly like decidim-bih's own MI_ICONS block: core's and
# decidim_awesome's register_icons initializers have all run by then, so the
# "already registered" guard is meaningful and we never re-register a name they
# own (which trips a deprecation warning).
Rails.application.config.after_initialize do
  DecidimAppLaunchModeInitializer::LAUNCH_ICONS.each do |name, description|
    next if Decidim.icons.all.has_key?(name)

    Decidim.icons.register(name:, icon: name, category: "system", description:, engine: :core)
  end
end

Rails.application.config.to_prepare do
  if Decidim::Bih.respond_to?(:mi_hero_ctas=) && Decidim::Bih.respond_to?(:mi_hero_stat_min=)
    Decidim::Bih.mi_hero_ctas = lambda do |organization = nil|
      DecidimAppLaunchModeInitializer.launch_ctas if DecidimAppLaunchModeInitializer.active?(organization)
    end

    Decidim::Bih.mi_hero_stat_min = lambda do |organization = nil|
      DecidimAppLaunchModeInitializer.active?(organization) ? DecidimAppLaunchModeInitializer::HERO_STAT_MIN : 0
    end
  else
    DecidimAppLaunchModeInitializer.warn_hero_accessors_missing
  end
end

# Main navigation, desktop and mobile. Registered once at boot; the block body
# runs per request, which is where current_organization exists.
[:menu, :mobile_menu].each do |menu_name|
  Decidim.menu menu_name do |menu|
    organization = respond_to?(:current_organization, true) ? current_organization : nil
    next unless organization

    unless DecidimApp::LaunchMode.active?(organization)
      next if DecidimApp::LaunchMode.race_archived?(organization)

      menu.add_item :bih_race, I18n.t("decidim.bih.menu.race"),
                    Rails.application.routes.url_helpers.launch_race_rules_path,
                    position: 1.16, active: :inclusive
      next
    end

    # Decidim::Menu#remove_item only records the identifier and filters it out
    # in #items, so removing an id the engine did not register is a harmless
    # no-op rather than a raise — these stay unguarded on purpose, so a renamed
    # engine item shows up as a stale entry in the menu, not a 500.
    menu.remove_item :bih_volunteer
    menu.remove_item :bih_donations
    menu.remove_item :bih_impact

    menu.add_item :bih_race,
                  I18n.t("decidim.bih.menu.race"),
                  Rails.application.routes.url_helpers.launch_race_rules_path,
                  position: 1.16,
                  active: :inclusive

    menu.add_item :bih_mi_bot,
                  I18n.t("decidim.bih.menu.mi_bot_short"),
                  Decidim::Bih.public_path("mi-bot"),
                  position: 1.17,
                  active: :inclusive
  end
end
