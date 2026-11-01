# frozen_string_literal: true

# Bijeljina mounts Decidim::Bih::Engine at /biceriseno in config/routes.rb.
# Keep the engine URL helper setting explicit and fail fast if an environment
# override drifts away from the real mount path.
public_mount_path = Decidim::Bih.normalize_public_mount_path(
  ENV.fetch("DECIDIM_BIH_PUBLIC_MOUNT_PATH", "/biceriseno")
)

raise "DECIDIM_BIH_PUBLIC_MOUNT_PATH must be /biceriseno for this host; update config/routes.rb before changing it" unless public_mount_path == "/biceriseno"

Decidim::Bih.public_mount_path = public_mount_path

magic_link_short_value = ENV.fetch("DECIDIM_BIH_MAGIC_LINK_SHORT_PATH_ENABLED", "true")
Decidim::Bih.magic_link_short_path_enabled =
  !magic_link_short_value.match?(/\A(false|0|no)\z/i)
