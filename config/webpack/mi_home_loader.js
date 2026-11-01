// Apply only to the opt-in anonymous homepage entry. Fail on upstream changes
// instead of silently widening scope. Other pages keep the complete core pack.
module.exports = function(source) {
  const chart = 'import "chartkick/chart.js"';
  const controllers = 'require.context("./controllers", true, /controller\\.js$/)';
  const registration = 'application.load(definitionsFromContext(context))';
  if (!source.includes(chart) || !source.includes(controllers) || !source.includes(registration)) {
    throw new Error("Decidim index changed: review MI homepage dependency selection");
  }
  // These optional form widgets are not part of homepage content. Preserve
  // support if a remote dialog introduces them, without shipping their data and
  // third-party libraries (Emoji Mart, TomSelect, date picker) on first paint.
  const eager = 'require.context("./controllers", true, /^(?!.*\\/(?:editor|emoji|input_tags|multiple_mentions|date_picker)\\/).*controller\\.js$/)';
  const lazy = 'require.context("./controllers", true, /^\\.\\/(?:emoji|input_tags|multiple_mentions|date_picker)\\/controller\\.js$/, "lazy")';
  return source.replace(chart, 'import registerLazyControllers from "src/decidim/mi_home_lazy_controllers";')
    .replace(controllers, eager)
    .replace(registration, `${registration}\nregisterLazyControllers(application, ${lazy});`);
};
