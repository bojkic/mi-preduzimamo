# frozen_string_literal: true

# Instalacija ne pravi demo naloge sa poznatim lozinkama po podrazumijevanim postavkama.
# Samo za lokalni razvoj: MI_LOAD_SYNTHETIC_EXAMPLES=true bin/rails db:seed
if ENV["MI_LOAD_SYNTHETIC_EXAMPLES"] == "true"
  abort "Demo seed je dozvoljen samo u development okruženju." unless Rails.env.development?

  Decidim.seed!
end
