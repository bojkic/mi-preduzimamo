# frozen_string_literal: true

source "https://rubygems.org"

ruby RUBY_VERSION

gem "decidim", "0.32.2"
gem "rails", "8.1.4"

# Shared Bosnian-market customizations (locales, theme base, overrides).
# Local dev uses a path override: `bundle config set local.decidim-bih ../mi-preduzimamo-engine`
gem "decidim-bih", git: "https://github.com/bojkic/mi-preduzimamo-engine.git", branch: "main",
                   ref: "8fb44caaf22ebd8369bfb4d4cf5954f55298ad3d"

# Customization/admin power layer — structured proposal fields, scoped CSS branding,
# weighted voting, anti-spam. 0.15.x targets Decidim 0.32.x; use an immutable upstream commit.
# Its webpack packs need npm deps (codemirror, form-storage, formBuilder,
# formbuilder-languages, inline-attacher, jsrender, leaflet.featuregroup.subgroup)
# in package.json — added below — then a full shakapacker:compile.
gem "decidim-decidim_awesome", git: "https://github.com/decidim-ice/decidim-module-decidim_awesome.git",
                                ref: "b54294b7f4f991886dc75f8f94bb558105b768b8"

# gem "decidim-ai", "0.31.5"
# gem "decidim-collaborative_texts", "0.31.5"
# gem "decidim-conferences", "0.31.5"
# gem "decidim-demographics", "0.31.5"
# gem "decidim-design", "0.31.5"
# gem "decidim-elections", "0.31.5"
# gem "decidim-initiatives", "0.31.5"
# gem "decidim-templates", "0.31.5"

gem "bootsnap", "~> 1.3", require: false # config/boot.rb owns explicit setup.
gem "pdf-reader", "~> 2.0"

gem "puma", ">= 6.3.1"
gem "sidekiq", "~> 7.3"

# Default gems have 2026 advisories; retain fixed release pins
# when upgrading the interpreter (dependency audit 2026-10-21, Stage A):
# resolv 0.3.2 fixes CVE-2025-24294 / CVE-2026-80212 / CVE-2026-80213 (reached by the
# email validator's disposable-domain MX lookup); zlib 3.1.2 fixes CVE-2026-27820.
gem "resolv", "~> 0.3.2"
gem "zlib", "~> 3.1.2"

group :development, :test do
  gem "byebug", "~> 11.0", platform: :mri

  gem "brakeman", "~> 7.0"
  gem "decidim-dev", "0.32.2"
  # Standalone contracts use the Minitest 5 API; Rails 8.1 supports this line.
  gem "minitest", "~> 5.27"
  gem "net-imap", "~> 0.5.0"
  gem "net-pop", "~> 0.1.1"
end

group :development do
  gem "letter_opener_web", "~> 2.0"
  gem "listen", "~> 3.1"
  gem "web-console", "~> 4.2"
end
