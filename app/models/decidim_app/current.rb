# frozen_string_literal: true

module DecidimApp
  # Per-request scratch space, reset for us by the Rails executor at the end of
  # every request and every job — so nothing stored here can leak from one
  # citizen's request into the next one's.
  #
  # `launch_mode_by_org` memoizes DecidimApp::LaunchMode.active? per
  # organization id (spec 6.1: the predicate is cached per request). One render
  # asks it six or more times — menu and mobile_menu, the hero's CTA list, the
  # hero's stat floor, the desktop header, the quick-action launcher and the
  # mobile bottom nav — and each miss is a Setting lookup. Caching it per
  # REQUEST rather than at boot is what keeps the 14.10.2026 20:00 freeze and
  # the operator's Setting(launch, mode) override deploy-free: the next request
  # re-reads them.
  class Current < ActiveSupport::CurrentAttributes
    attribute :launch_mode_by_org
  end
end
