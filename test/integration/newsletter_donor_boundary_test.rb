# frozen_string_literal: true

require "test_helper"

# Owner decision D12, enforced on the HOST half of the split.
#
#   MI's newsletter carries platform news to citizens.
#   Odoo carries donations, donors and fundraising campaigns.
#
# The engine proves its own sources clean; this proves the host's. The scanner
# is the engine's (`Decidim::Bih::NewsletterEligibilityBoundary`) so there is
# one rule rather than two regexes that drift apart.
class NewsletterDonorBoundaryTest < ActiveSupport::TestCase
  BOUNDARY = Decidim::Bih::NewsletterEligibilityBoundary

  def host_sources
    Dir[Rails.root.join("app/**/*.rb")] + Dir[Rails.root.join("lib/**/*.rb")]
  end

  test "no host source records or selects a donor communication preference" do
    assert_empty BOUNDARY.scan(host_sources).map { |row| row.sub("#{Rails.root}/", "") },
                 "Odoo owns the donor audience; MI must hold no donor mailing preference"
  end

  # MI's Odoo mirror is an aggregate of donation TOTALS. If it ever started
  # carrying people, the split would be broken at the data layer rather than
  # at a query, and the scan above would not see it.
  test "the Odoo mirror carries totals, not donors" do
    source = File.read(Rails.root.join("app/services/decidim_app/bijeljina/donations.rb"))
    assert_empty BOUNDARY.offending_windows(source)
  end

  test "the schema declares no donor communication column" do
    schema = File.read(Rails.root.join("db/schema.rb"))
    offenders = schema.lines.select do |line|
      BOUNDARY::DONOR_CONCEPTS.any? { |concept| line.match?(BOUNDARY.token(concept)) } &&
        BOUNDARY::COMMUNICATION_CONCEPTS.any? { |concept| line.match?(BOUNDARY.token(concept)) }
    end

    assert_empty offenders.map(&:strip)
  end

  # A scan that cannot fail is not a guard.
  test "the host scan catches the column it exists to forbid" do
    refute_empty BOUNDARY.offending_windows("t.boolean :donor_newsletter_opt_in\n")
  end
end
