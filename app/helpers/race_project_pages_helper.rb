# frozen_string_literal: true

module RaceProjectPagesHelper
  def mi_project_campaign?(space = current_participatory_space)
    space.respond_to?(:slug) && space.slug == DecidimApp::Bijeljina::RaceProjectSelection::PROCESS_SLUG
  end

  def mi_project_phase(process)
    process.active_step&.position.to_i.clamp(0, 3)
  end

  def mi_project_name(component)
    Decidim::Bih::Transliterator.localize(translated_attribute(component.name), locale: I18n.locale)
  end

  def mi_project_link(component, submit: false)
    router = Decidim::EngineRouter.main_proxy(component)
    submit ? router.new_proposal_path(locale: I18n.locale) : router.root_path(locale: I18n.locale)
  end

  def mi_project_home
    "#{DecidimApp::Bijeljina::RaceProjectSelection.process_path}?locale=#{I18n.locale}"
  end
end
