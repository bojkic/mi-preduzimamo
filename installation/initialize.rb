# frozen_string_literal: true

# Called only after db:prepare on this installer's own new volume.
identity = ENV.fetch("MI_INSTALL_ID")
abort "Invalid installer identity" unless identity.match?(/\Ami-[0-9a-f]{16}\z/)
metadata = ActiveRecord::Base.connection_pool.internal_metadata
existing = metadata["mi_installation_id"]
if existing
  abort "Database belongs to another installation" unless existing == identity
else
  abort "Refusing to adopt an existing community" if Decidim::Organization.exists? || Decidim::System::Admin.exists?
  metadata["mi_installation_id"] = identity
end
puts "installation_identity=bound"
