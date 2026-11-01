/* Report intake location picker + photo picker. Requires Leaflet as window.L. */
(function () {
  "use strict";

  function ready(fn) {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", fn, { once: true });
    } else {
      fn();
    }
  }

  function coordinate(value) {
    return parseFloat(value);
  }

  function validLatLng(lat, lng) {
    return Number.isFinite(lat) && Number.isFinite(lng) &&
      lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
  }

  function csrfToken() {
    var meta = document.querySelector('meta[name="csrf-token"]');
    return meta ? meta.getAttribute("content") : null;
  }

  var DESKTOP = "(min-width: 761px)";

  /* ─── Location ─────────────────────────────────────────────────────────── */

  function initLocation() {
    var mapEl = document.getElementById("bih-report-location-map");
    if (!mapEl || mapEl.dataset.initialized === "true") return;

    var latInput = document.getElementById(mapEl.dataset.latitudeInputId || "report_latitude");
    var lngInput = document.getElementById(mapEl.dataset.longitudeInputId || "report_longitude");
    var addressInput = document.getElementById(mapEl.dataset.addressInputId || "report_address");
    var geolocate = document.getElementById(mapEl.dataset.geolocateButtonId || "bih-report-geolocate");
    var geocode = document.getElementById(mapEl.dataset.geocodeButtonId || "bih-report-geocode");
    var details = document.getElementById(mapEl.dataset.detailsId || "bih-report-map-details");
    var status = document.getElementById(mapEl.dataset.statusId || "bih-report-location-status");

    if (!latInput || !lngInput || !status) return;
    mapEl.dataset.initialized = "true";

    function say(text, tone) {
      status.textContent = text;
      status.dataset.tone = tone || "info";
    }

    if (typeof L === "undefined") {
      say(mapEl.dataset.statusUnavailable, "error");
      return;
    }

    /* The map lives inside a <details>: closed on phones (the citizen gets
       geolocation and the address first), open on wider screens. */
    if (details && !details.open && window.matchMedia(DESKTOP).matches) {
      details.open = true;
    }

    var center = [parseFloat(mapEl.dataset.centerLat), parseFloat(mapEl.dataset.centerLng)];
    var map = L.map(mapEl).setView(center, parseInt(mapEl.dataset.zoom, 10));
    var marker = null;

    L.tileLayer(mapEl.dataset.tileUrl, {
      maxZoom: parseInt(mapEl.dataset.tileMaxZoom || "19", 10),
      attribution: mapEl.dataset.tileAttribution
    }).addTo(map);

    if (details) {
      details.addEventListener("toggle", function () {
        if (details.open) {
          window.setTimeout(function () { map.invalidateSize(); }, 50);
        }
      });
    }

    function reveal() {
      if (details && !details.open) details.open = true;
      window.setTimeout(function () { map.invalidateSize(); }, 50);
    }

    function store(lat, lng) {
      latInput.value = lat.toFixed(6);
      lngInput.value = lng.toFixed(6);
      say(mapEl.dataset.statusSelected, "ok");
    }

    function setMarker(lat, lng, recenter) {
      if (!validLatLng(lat, lng)) return;

      var latLng = [lat, lng];
      if (marker) {
        marker.setLatLng(latLng);
      } else {
        marker = L.marker(latLng, { draggable: true }).addTo(map);
        marker.on("dragend", function () {
          var next = marker.getLatLng();
          store(next.lat, next.lng);
        });
      }

      store(lat, lng);
      if (recenter) {
        reveal();
        window.setTimeout(function () {
          map.invalidateSize();
          map.setView(latLng, Math.max(map.getZoom(), 16));
        }, 60);
      }
    }

    map.on("click", function (event) {
      setMarker(event.latlng.lat, event.latlng.lng, false);
    });

    var initialLat = coordinate(latInput.value);
    var initialLng = coordinate(lngInput.value);
    if (validLatLng(initialLat, initialLng)) {
      setMarker(initialLat, initialLng, true);
    }

    if (geolocate) {
      geolocate.addEventListener("click", function () {
        if (!navigator.geolocation) {
          say(mapEl.dataset.statusUnavailable, "error");
          return;
        }

        geolocate.disabled = true;
        say(mapEl.dataset.statusLocating, "busy");
        navigator.geolocation.getCurrentPosition(
          function (position) {
            geolocate.disabled = false;
            setMarker(position.coords.latitude, position.coords.longitude, true);
          },
          function () {
            geolocate.disabled = false;
            say(mapEl.dataset.statusError, "error");
          },
          { enableHighAccuracy: true, timeout: 10000, maximumAge: 300000 }
        );
      });
    }

    /* Address → point. Reuses the komšiluk suggest endpoint, which answers
       with lat/lon whenever Nominatim resolved the address. */
    if (geocode && addressInput) {
      function lookup() {
        var address = addressInput.value.trim();
        if (!address) { addressInput.focus(); return; }

        geocode.disabled = true;
        say(mapEl.dataset.statusGeocoding, "busy");

        var token = csrfToken();
        var body = new URLSearchParams({ address: address });
        if (token) body.append("authenticity_token", token);
        var headers = {
          "Content-Type": "application/x-www-form-urlencoded",
          "Accept": "application/json",
          "X-Requested-With": "XMLHttpRequest"
        };
        if (token) headers["X-CSRF-Token"] = token;

        fetch(geocode.dataset.geocodeUrl, { method: "POST", headers: headers, body: body.toString(), credentials: "same-origin" })
          .then(function (r) {
            if (!r.ok) throw new Error("geocode unavailable");
            return r.json();
          })
          .then(function (data) {
            geocode.disabled = false;
            var lat = parseFloat(data.lat);
            var lng = parseFloat(data.lon);
            if (validLatLng(lat, lng)) {
              setMarker(lat, lng, true);
            } else {
              say(mapEl.dataset.statusAddressNotFound, "error");
              reveal();
            }
          })
          .catch(function () {
            geocode.disabled = false;
            say(mapEl.dataset.statusAddressNotFound, "error");
            reveal();
          });
      }

      geocode.addEventListener("click", lookup);
      addressInput.addEventListener("keydown", function (e) {
        if (e.key === "Enter") { e.preventDefault(); lookup(); }
      });
    }
  }

  /* ─── Photo ────────────────────────────────────────────────────────────── */

  function initPhoto() {
    var input = document.getElementById("report_photo");
    var preview = document.getElementById("bih-report-photo-preview");
    var thumb = document.getElementById("bih-report-photo-thumb");
    var name = document.getElementById("bih-report-photo-name");
    var remove = document.getElementById("bih-report-photo-remove");
    if (!input || !preview || input.dataset.bound === "true") return;
    input.dataset.bound = "true";

    var objectUrl = null;

    function clear() {
      if (objectUrl) { URL.revokeObjectURL(objectUrl); objectUrl = null; }
      if (thumb) thumb.removeAttribute("src");
      if (name) name.textContent = "";
      preview.hidden = true;
    }

    function show(file) {
      clear();
      if (!file) return;
      if (thumb && window.URL && file.type && file.type.indexOf("image/") === 0) {
        objectUrl = URL.createObjectURL(file);
        thumb.src = objectUrl;
      }
      if (name) name.textContent = file.name;
      preview.hidden = false;
    }

    input.addEventListener("change", function () {
      show(input.files && input.files[0]);
    });

    if (remove) {
      remove.addEventListener("click", function () {
        input.value = "";
        clear();
        input.focus();
      });
    }
  }

  function init() {
    initLocation();
    initPhoto();
  }

  ready(init);
  document.addEventListener("turbo:load", init);
})();
