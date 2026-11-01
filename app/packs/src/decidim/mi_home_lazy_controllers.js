import { Controller } from "@hotwired/stimulus";
import { identifierForContextKey } from "src/decidim/refactor/support/stimulus";

// Keep navigation, consent and dialogs eager. Only optional form widgets use
// placeholders: Stimulus connects them if their markup is present now or added
// by a remote dialog, then reconnects with the real controller after import.
export default function registerLazyControllers(application, context) {
  context.keys().forEach((key) => {
    const identifier = identifierForContextKey(key);
    if (!identifier) return;
    let pending;
    application.register(identifier, class extends Controller {
      connect() {
        if (pending) return;
        pending = context(key).then((module) => {
          application.register(identifier, module.default);
        }).catch((error) => {
          pending = null;
          console.error(`Unable to load optional ${identifier} widget`, error);
        });
      }
    });
  });
}
