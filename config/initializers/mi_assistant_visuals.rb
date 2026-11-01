# frozen_string_literal: true

# These host-owned files are distributed in public/mi/milica. The reusable
# engine still assumes no assets. Empty values explicitly hide the persona.
Decidim::Bih.mi_bot_persona_image_path = ENV.fetch("MI_ASSISTANT_IMAGE_PATH", "/mi/milica/wave.gif").presence
Decidim::Bih.mi_bot_persona_static_image_path = ENV.fetch("MI_ASSISTANT_STATIC_IMAGE_PATH", "/mi/milica/wave.jpg").presence
