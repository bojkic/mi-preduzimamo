// This file is compiled inside Decidim core pack. Code can be added here and will be executed
// as part of that pack

// Load images
require.context("../../images", true)

// Shared locale handling is supplied by the engine; load it in every core pack.
import "src/decidim/bih/calendar_locale";
