# frozen_string_literal: true

namespace :mi do
  desc <<~DESC
    Unpublish the demo participatory-budget component that used to advertise a
    "600.000 KM" figure the client retracted.
    Usage: rake "mi:unpublish_demo_budget[org.host.com]"        # DRY RUN, prints only
           rake "mi:unpublish_demo_budget[org.host.com,apply]"  # unpublishes

    DRY RUN IS THE DEFAULT. Matches by IDENTITY, never by amount: a published
    budgets component is only a candidate when it sits in the "ti-se-pitas-2026"
    grant cycle AND holds a budget titled "Budžet za sve nas!" — the exact demo
    DecidimApp::Bijeljina::DemoSeed used to seed (including the invented "Novi
    vrtić u Ledincima" project, before that seeding was removed). A genuine
    participatory budget the foundation runs later, under any other title or
    space, is never touched, no matter its total. Unpublishing is REVERSIBLE
    and keeps the data; nothing is deleted.
  DESC
  task :unpublish_demo_budget, [:org_host, :mode] => :environment do |_task, args|
    org_host = args[:org_host]
    mode = args[:mode].to_s
    abort "Usage: rake \"mi:unpublish_demo_budget[org_host,apply]\"" if org_host.blank?

    organization = Decidim::Organization.find_by(host: org_host)
    abort "Organization not found for host: #{org_host}" unless organization

    demo_grant_cycle_slug = "ti-se-pitas-2026"
    demo_budget_title = "Budžet za sve nas!"
    apply = mode == "apply"

    candidates = Decidim::Component
                 .where(manifest_name: "budgets")
                 .where.not(published_at: nil)
                 .select do |component|
                   space = component.participatory_space
                   next false unless space.respond_to?(:organization_id) && space.organization_id == organization.id
                   next false unless space.respond_to?(:slug) && space.slug == demo_grant_cycle_slug

                   Decidim::Budgets::Budget.where(component:).any? { |budget| budget.title["sr"] == demo_budget_title }
                 end

    if candidates.empty?
      puts "No published demo budget component found for #{org_host} " \
           "(looking for a \"#{demo_budget_title}\" budget in \"#{demo_grant_cycle_slug}\")."
      next
    end

    candidates.each do |component|
      total = Decidim::Budgets::Budget.where(component:).sum(:total_budget).to_i

      if apply
        component.update!(published_at: nil)
        puts "Unpublished component ##{component.id} (#{component.name["sr"]}) — #{total} KM."
      else
        puts "Would unpublish component ##{component.id} (#{component.name["sr"]}) — #{total} KM. Re-run with ,apply to write."
      end
    end

    puts(apply ? "Done." : "DRY RUN — nothing written. Re-run with ,apply to write.")
  end
end
