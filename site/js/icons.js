// Icons for the elements and Homeland abilities.
// Official game icons listed in site/icons/icons.json ({ "Fire": "fire.png", ... }) are
// used where present; anything not listed falls back to these hand-drawn SVGs
// (24x24, currentColor; each icon is a list of paths, `s` marks a stroked path).
(function (root) {
  'use strict';

  const ICONS = {
    Fire: [{ d: 'M12 2c.6 3.6 5.5 6.2 5.5 11.3A5.5 5.5 0 0 1 6.5 13.3c0-2.6 1.3-4.4 2.8-5.6.2 2.1 1 3.3 2.2 3.8C11 8.6 10.9 5.4 12 2z' }],
    Water: [{ d: 'M12 2.5C9 7 5.8 10.3 5.8 14.2a6.2 6.2 0 0 0 12.4 0c0-3.9-3.2-7.2-6.2-11.7z' }],
    Grass: [{ d: 'M20.5 3.5C9.5 3.5 4 8.8 4 15.8c0 1.5.3 2.8.9 3.9 1.8-5.8 5.4-9.4 10.4-11.5-4.1 2.6-7.1 6.3-8.5 12.1 1 .5 2.2.7 3.4.7 7.3 0 10.3-6.2 10.3-17.5z' }],
    Earth: [{ d: 'M1.5 20.5 8.8 6.5l4.2 7.4 2.6-4.3 6.9 10.9z' }],
    Lightning: [{ d: 'M13.5 1.5 3.8 14h6.4l-1.4 8.5L19.2 9.6h-6.6z' }],
    Ice: [{ s: true, d: 'M12 2v20M3.3 7l17.4 10M3.3 17 20.7 7M9.5 3.8 12 6l2.5-2.2M9.5 20.2 12 18l2.5 2.2M4 10.7l3.1-1L6.4 6.5M20 13.3l-3.1 1 .7 3.2M4 13.3l3.1 1-.7 3.2M20 10.7l-3.1-1 .7-3.2' }],
    Wind: [{ s: true, d: 'M2.5 8.5h11a3 3 0 1 0-3-3M2.5 12.5h16a3 3 0 1 1-3 3M2.5 16.5h7' }],
    Dark: [{ d: 'M20.5 14.6A8.8 8.8 0 1 1 9.4 3.5a7.2 7.2 0 0 0 11.1 11.1z' }],
    Light: [{ d: 'M12 7.5a4.5 4.5 0 1 1 0 9 4.5 4.5 0 0 1 0-9z' },
            { s: true, d: 'M12 1.5v2.5M12 20v2.5M1.5 12H4M20 12h2.5M4.6 4.6l1.8 1.8M17.6 17.6l1.8 1.8M4.6 19.4l1.8-1.8M17.6 6.4l1.8-1.8' }],
    Hauling: [{ s: true, d: 'M3 7.2 12 3l9 4.2v9.6L12 21l-9-4.2zM3 7.2l9 4.2 9-4.2M12 11.4V21M7.5 5.1l9 4.2' }],
    Artisanship: [{ s: true, d: 'M3.5 20.5l8.8-8.8' }, { d: 'M9.6 7.9 15 2.5l6.5 6.5-5.4 5.4z' }],
    Leisure: [{ d: 'M9 18.2a3.2 3.2 0 1 1-2-3V4.8L20 2.5v12.7a3.2 3.2 0 1 1-2-3V6.5L9 8.1z' }],
    Perfumery: [{ d: 'M9.5 1.5h5v3h-5zM8 6h8l2.5 3.5v10.3a2.2 2.2 0 0 1-2.2 2.2H7.7a2.2 2.2 0 0 1-2.2-2.2V9.5z' }],
  };

  const NS = 'http://www.w3.org/2000/svg';
  let official = {};

  // Load the list of official icon files. Missing or broken list = use the SVGs.
  async function loadOfficial() {
    try {
      const res = await fetch('icons/icons.json');
      if (res.ok) official = await res.json();
    } catch (e) { /* keep the SVG icons */ }
  }

  // Returns an icon element for `name`, or null if there's no icon for it.
  function icon(name) {
    if (official[name]) {
      const img = document.createElement('img');
      img.src = 'icons/' + official[name];
      img.alt = '';
      img.className = 'ico ico-img';
      img.decoding = 'async';
      return img;
    }
    const paths = ICONS[name];
    if (!paths) return null;
    const svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('class', 'ico');
    svg.setAttribute('aria-hidden', 'true');
    for (const p of paths) {
      const path = document.createElementNS(NS, 'path');
      path.setAttribute('d', p.d);
      if (p.s) {
        path.setAttribute('fill', 'none');
        path.setAttribute('stroke', 'currentColor');
        path.setAttribute('stroke-width', '2');
        path.setAttribute('stroke-linecap', 'round');
        path.setAttribute('stroke-linejoin', 'round');
      } else {
        path.setAttribute('fill', 'currentColor');
      }
      svg.append(path);
    }
    return svg;
  }

  root.AniimoIcons = { icon, loadOfficial };
})(window);
