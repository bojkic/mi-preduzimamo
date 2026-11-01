/* Expand the selected notice without squeezing its editor into a table column. */
(function () {
  if (window.miCityAlertsReviewBound) return;
  window.miCityAlertsReviewBound = true;
  function openPanel(id) {
    const panel = document.getElementById('city-alert-editor-' + id);
    const buttons = document.querySelectorAll('[data-city-alert-toggle="' + id + '"]');
    if (!panel || !buttons.length) return;
    panel.hidden = false;
    buttons.forEach(button => button.setAttribute('aria-expanded', 'true'));
  }
  function configureMobileDisclosures() {
    const mobile = window.matchMedia('(max-width: 1000px)');
    function apply() {
      document.querySelectorAll('[data-city-mobile-collapse]').forEach(function (panel) {
        panel.open = !mobile.matches || panel.hasAttribute('data-city-keep-open');
      });
    }
    apply();
    mobile.addEventListener('change', apply);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', configureMobileDisclosures);
  else configureMobileDisclosures();
  function openFailedNotice() {
    const match = window.location.hash.match(/^#city-service-event-(\d+)$/);
    if (match) openPanel(match[1]);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', openFailedNotice);
  else openFailedNotice();
  window.addEventListener('hashchange', openFailedNotice);

  document.addEventListener('change', function (event) {
    const facts = event.target.closest('[data-city-review-facts]');
    if (!facts) return;
    const areas = facts.querySelector('select[name="city_service_event[area_ids][]"]');
    const kind = facts.querySelector('select[name="city_service_event[targeting_level]"]');
    const confirmation = facts.querySelector('input[name="city_service_event[facts_reviewed]"]');
    if (!areas || !kind || !confirmation) return;
    areas.setCustomValidity('');
    const proposal = event.target.closest('[data-city-area-proposal]');
    if (proposal) {
      proposal.querySelector('[data-city-confirm-areas]').disabled = !proposal.querySelector('[data-city-proposed-area]:checked');
      if (facts.dataset.confirmedProposal === proposal.dataset.cityAreaProposal) {
        Array.from(areas.options).forEach(option => { option.selected = false; });
        kind.value = 'unknown';
        confirmation.checked = false;
        delete facts.dataset.confirmedProposal;
      }
    }
    if (event.target === areas || event.target.closest('[data-city-area-proposal]') || event.target === kind) {
      const status = facts.querySelector('[data-city-area-confirmation-status]');
      if (status) status.textContent = '';
    }
    if (event.target === areas) {
      const kinds = [...new Set(Array.from(areas.selectedOptions).filter(o => o.value).map(o => o.dataset.areaKind))];
      if (kinds.length === 1) kind.value = kinds[0];
    }
    const changed = Array.from(areas.options).some(o => o.selected !== o.defaultSelected) || kind.value !== facts.dataset.initialKind;
    confirmation.required = changed;
    if (changed) facts.open = true;
    const note = facts.closest('form').querySelector('[name="city_service_event[review_note]"]');
    if (note) {
      note.required = confirmation.checked;
      if (note.required && note.closest('details')) note.closest('details').open = true;
    }
  });

  document.addEventListener('submit', function (event) {
    if (!event.submitter || event.submitter.name !== 'review_action' || event.submitter.value !== 'publish') return;
    const facts = event.target.querySelector('[data-city-review-facts]');
    if (!facts) return;
    const areas = facts.querySelector('select[name="city_service_event[area_ids][]"]');
    const kind = facts.querySelector('select[name="city_service_event[targeting_level]"]');
    const selected = Array.from(areas.selectedOptions).filter(o => o.value);
    const valid = kind.value === 'citywide' ? selected.length === 0 :
      ['mz', 'komsiluk'].includes(kind.value) && selected.length > 0 && selected.every(o => o.dataset.areaKind === kind.value);
    if (valid) return;
    event.preventDefault();
    facts.open = true;
    facts.querySelector('[data-city-manual-areas]').open = true;
    areas.setCustomValidity(facts.dataset.noAreaMessage);
    areas.focus();
    areas.reportValidity();
  });

  document.addEventListener('click', function (event) {
    const confirm = event.target.closest('[data-city-confirm-areas]');
    if (confirm) {
      const facts = confirm.closest('[data-city-review-facts]');
      const proposal = confirm.closest('[data-city-area-proposal]');
      const choices = Array.from(proposal.querySelectorAll('[data-city-proposed-area]:checked'));
      if (!choices.length) return;
      const ids = choices.map(input => input.value);
      const areas = facts.querySelector('select[name="city_service_event[area_ids][]"]');
      Array.from(areas.options).forEach(option => { option.selected = ids.includes(option.value); });
      areas.dispatchEvent(new Event('change', { bubbles: true }));
      const confirmation = facts.querySelector('input[name="city_service_event[facts_reviewed]"]');
      confirmation.checked = true;
      confirmation.dispatchEvent(new Event('change', { bubbles: true }));
      facts.dataset.confirmedProposal = proposal.dataset.cityAreaProposal;
      const proposals = confirm.closest('[data-city-proposed-areas]');
      const note = facts.closest('form').querySelector('[name="city_service_event[review_note]"]');
      if (note && !note.value.trim()) note.value = proposals.dataset.confirmationNote;
      const status = proposals.querySelector('[data-city-area-confirmation-status]');
      status.textContent = status.dataset.confirmedLabel + ' ' + choices.map(input => input.closest('label').textContent.trim()).join(', ');
      return;
    }
    const button = event.target.closest('[data-city-alert-toggle]');
    if (!button) return;
    const panel = document.getElementById(button.getAttribute('aria-controls'));
    if (!panel) return;
    panel.hidden = button.hasAttribute('data-city-correct') ? false : !panel.hidden;
    if (button.hasAttribute('data-city-correct')) {
      const withdrawal = panel.querySelector('[data-city-alert-withdraw]');
      if (withdrawal) {
        withdrawal.open = true;
        const note = withdrawal.querySelector('input[name="review_note"]');
        if (note) note.focus();
      }
    }
    document.querySelectorAll('[data-city-alert-toggle="' + button.dataset.cityAlertToggle + '"]').forEach(toggle => {
      toggle.setAttribute('aria-expanded', String(!panel.hidden));
    });
  });
}());
/* Lazy geometry, independent board selection, and an equivalent keyboard list. */
(function () {
  let leaflet;
  function loadLeaflet() {
    if (window.L) return Promise.resolve();
    if (!leaflet) leaflet = new Promise((resolve, reject) => {
      const css = document.createElement('link'); css.rel = 'stylesheet'; css.href = '/leaflet/leaflet.css'; document.head.append(css);
      const script = document.createElement('script'); script.src = '/leaflet/leaflet.js'; script.onload = resolve; script.onerror = reject; document.head.append(script);
    });
    return leaflet;
  }
  function initializeList(root) {
    if (root.dataset.listReady) return;
    root.dataset.listReady = '1';
    const form = root.closest('form');
    const select = form.querySelector('select[name="city_service_event[area_ids][]"]');
    const list = root.querySelector('[data-city-board-list]');
    Array.from(select.options).filter(o => o.dataset.areaKind === 'komsiluk').forEach(option => {
      const label = document.createElement('label');
      const input = document.createElement('input'); input.type = 'checkbox'; input.value = option.value; input.checked = option.selected;
      input.addEventListener('change', () => {
        Array.from(select.options).filter(o => o.dataset.areaKind !== 'komsiluk').forEach(o => { o.selected = false; });
        option.selected = input.checked; select.dispatchEvent(new Event('change', { bubbles: true }));
      });
      label.append(input, document.createTextNode(option.textContent)); list.append(label);
    });
    select.addEventListener('change', () => list.querySelectorAll('input').forEach(input => { input.checked = Array.from(select.selectedOptions).some(o => o.value === input.value); }));
    root.querySelector('[data-city-board-search]').addEventListener('input', event => list.querySelectorAll('label').forEach(label => { label.hidden = !label.textContent.toLocaleLowerCase().includes(event.target.value.toLocaleLowerCase()); }));
  }
  function init() { document.querySelectorAll('[data-city-map-url]').forEach(initializeList); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
  document.addEventListener('click', async event => {
    const button = event.target.closest('[data-city-load-map]'); if (!button) return;
    const root = button.closest('[data-city-map-url]'); const status = root.querySelector('[data-city-map-status]');
    button.disabled = true;
    try {
      const response = await fetch(root.dataset.cityMapUrl, { credentials: 'same-origin', headers: { Accept: 'application/json' } });
      if (!response.ok) throw new Error('map');
      const data = await response.json();
      if (data.review_token !== root.dataset.reviewToken) { status.textContent = root.dataset.staleLabel; return; }
      await loadLeaflet();
      const canvas = root.querySelector('[data-city-map-canvas]'); canvas.hidden = false;
      const map = L.map(canvas);
      if (root.dataset.tileUrl) L.tileLayer(root.dataset.tileUrl, { maxZoom: 19, attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>' }).addTo(map);
      const selected = root.closest('form').querySelector('select[name="city_service_event[area_ids][]"]');
      const boardSelected = feature => Array.from(selected.selectedOptions).some(o => o.value === String(feature.properties.id) || (feature.properties.mz_ids || []).map(String).includes(o.value));
      const style = feature => ({ color: boardSelected(feature) ? '#185adb' : '#64748b', weight: 2, fillOpacity: .08 });
      const boards = L.geoJSON(data.features.filter(f => f.properties.kind === 'komsiluk'), { style, onEachFeature(feature, layer) {
        const text = document.createElement('span'); text.textContent = feature.properties.name; layer.bindTooltip(text);
        layer.on('click', () => { const input = root.querySelector('[data-city-board-list] input[value="' + feature.properties.id + '"]'); if (input) { input.checked = !input.checked; input.dispatchEvent(new Event('change', { bubbles: true })); } });
      }}).addTo(map);
      const mz = L.geoJSON(data.features.filter(f => f.properties.kind === 'mz'), { style: { color: '#475569', dashArray: '5 5', fill: false, weight: 1 }, interactive: false });
      root.querySelector('[data-city-map-mz]').addEventListener('change', event => event.target.checked ? mz.addTo(map) : map.removeLayer(mz));
      const footprint = L.geoJSON(data.footprint, { style: { color: '#b45309', weight: 4, fillOpacity: .18 }, interactive: false }).addTo(map);
      selected.addEventListener('change', () => boards.setStyle(style));
      const fit = () => {
        const chosen = L.featureGroup(boards.getLayers().filter(layer => boardSelected(layer.feature)));
        const bounds = footprint.getBounds().isValid() ? footprint.getBounds() : (chosen.getBounds().isValid() ? chosen.getBounds() : boards.getBounds());
        if (bounds.isValid()) map.fitBounds(bounds, { padding: [15, 15] });
      };
      fit(); const fitButton = root.querySelector('[data-city-map-fit]'); fitButton.hidden = false; fitButton.addEventListener('click', fit);
      status.textContent = data.unknown_extent ? root.dataset.unknownLabel : '';
      button.hidden = true;
    } catch (_error) { status.textContent = root.dataset.errorLabel; button.disabled = false; }
  });
}());
(function () {
  function sync(form) {
    const checkbox = form.querySelector('[data-city-fallback]');
    const text = form.querySelector('[data-city-fallback-text]');
    const publish = form.querySelector('[data-fallback-label]');
    if (publish) {
      publish.dataset.normalLabel = publish.dataset.normalLabel || publish.textContent;
      publish.textContent = checkbox && checkbox.checked ? publish.dataset.fallbackLabel : publish.dataset.normalLabel;
    }
    if (text) { text.hidden = !checkbox || !checkbox.checked; text.open = !!checkbox && checkbox.checked; }
  }
  function init() { document.querySelectorAll('form.mi-admin-record-editor').forEach(sync); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
  document.addEventListener('change', event => { if (event.target.matches('[data-city-fallback]')) sync(event.target.closest('form')); });
}());
