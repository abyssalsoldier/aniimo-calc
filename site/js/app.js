(function () {
  'use strict';

  const STORAGE_KEY = 'aniimo-calc-v1';
  const $ = sel => document.querySelector(sel);

  // Ids that changed when the data source moved from metabot.gg to aniimotools.dev
  // (renamed forms and species; "Basic Form" entries were duplicates of the default form).
  const RENAMED_IDS = {
    'fennelun': 'lunara', 'soleon': 'helion',
    'magmarex-basic': 'magmarex', 'shelly-basic': 'shelly', 'susuta-basic': 'susuta',
    'tubster-basic': 'tubster', 'tuckin-basic': 'tuckin',
    'luminelle-rainstorm': 'luminelle-rainfall', 'nimbi-rainstorm': 'nimbi-rainfall',
    'stellarys-rainstorm': 'stellarys-rainfall', 'turbo-rainstorm': 'turbo-rainfall',
  };
  for (const n of ['blazen', 'bolty', 'emberpup', 'flameruff', 'flutternym', 'gracewing', 'helmut',
    'iris', 'irisal', 'pawney', 'rookey', 'scorchhowl']) RENAMED_IDS[`${n}-mountain-woods`] = `${n}-timberline`;
  for (const n of ['flamerion', 'flutternym', 'glacy', 'gracewing', 'pomawk', 'pomegg', 'pranky',
    'skippy', 'sparki']) RENAMED_IDS[`${n}-sea-of-flowers`] = `${n}-flowerfield`;

  let DATA = null;
  let state = loadState();

  function defaultState() {
    return {
      needs: {},            // ability -> { on, minLevel, count }
      maxCount: 45,
      allowPrismana: false,
      onlyOwned: false,
      multiRole: true,
      allowDupes: true,
      owned: [],            // aniimo ids
      showPrismana: true,
    };
  }

  function loadState() {
    try {
      const saved = JSON.parse(localStorage.getItem(STORAGE_KEY));
      if (saved) {
        if (Array.isArray(saved.owned)) saved.owned = [...new Set(saved.owned.map(id => RENAMED_IDS[id] || id))];
        return Object.assign(defaultState(), saved);
      }
    } catch (e) { /* storage unavailable */ }
    return defaultState();
  }

  function saveState() {
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(state)); } catch (e) { /* ignore */ }
  }

  function el(tag, attrs, ...children) {
    const node = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (k === 'class') node.className = v;
      else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
      else if (v === true) node.setAttribute(k, '');
      else if (v !== false && v != null) node.setAttribute(k, v);
    }
    for (const c of children.flat()) {
      if (c != null) node.append(c.nodeType ? c : document.createTextNode(c));
    }
    return node;
  }

  const displayName = a => a.form ? `${a.name} (${a.form})` : a.name;
  // The name links to the Aniimo's AniimoTools page (opens in a new tab)
  const wikiLink = (a, ...children) => a.wiki
    ? el('a', { class: 'wiki', href: a.wiki, target: '_blank', rel: 'noopener', title: `${displayName(a)} on AniimoTools` }, ...children)
    : el('span', null, ...children);
  const abilityClass = name => 'ab-' + name.toLowerCase();
  const icon = name => AniimoIcons.icon(name);

  function abilityBadge(name, level) {
    return el('span', { class: `badge ${abilityClass(name)}`, title: `${name} level ${level}` },
      icon(name), name, ' ', el('b', null, String(level)));
  }

  // ---------- Needs ----------

  function needFor(ability) {
    if (!state.needs[ability]) state.needs[ability] = { on: false, minLevel: 1, count: 1 };
    return state.needs[ability];
  }

  function renderNeeds() {
    const list = $('#req-list');
    list.replaceChildren();
    for (const ability of DATA.abilities) {
      const n = needFor(ability);
      const levelSel = el('select', { 'aria-label': `${ability} minimum level` },
        [1, 2, 3, 4].map(l => el('option', { value: l, selected: n.minLevel === l }, `Lv ${l}+`)));
      const count = el('input', { type: 'number', min: 1, max: 20, value: n.count, 'aria-label': `${ability} workers needed` });
      const box = el('input', { type: 'checkbox', checked: n.on, 'aria-label': `Need ${ability}` });
      const row = el('div', { class: 'req' + (n.on ? ' on' : '') },
        box, el('span', { class: `ab-name ${abilityClass(ability)}` }, icon(ability), ability), levelSel, count);

      const update = () => {
        n.on = box.checked;
        n.minLevel = +levelSel.value;
        n.count = Math.max(1, Math.min(20, +count.value || 1));
        row.classList.toggle('on', n.on);
        recalc();
      };
      box.addEventListener('change', update);
      levelSel.addEventListener('change', () => { box.checked = true; update(); });
      count.addEventListener('input', () => { box.checked = true; update(); });
      list.append(row);
    }
  }

  // ---------- Roster ----------

  function renderRoster() {
    const q = $('#search').value.trim().toLowerCase();
    const ability = $('#ability-filter').value;
    const owned = new Set(state.owned);
    const tbody = $('#aniimo-table tbody');
    const rows = [];

    for (const a of DATA.aniimo) {
      if (!state.showPrismana && a.prismana) continue;
      if (q && !displayName(a).toLowerCase().includes(q)) continue;
      if (ability && !a.abilities[ability]) continue;

      const box = el('input', { type: 'checkbox', checked: owned.has(a.id), 'aria-label': `Own ${displayName(a)}` });
      box.addEventListener('change', () => {
        const set = new Set(state.owned);
        if (box.checked) set.add(a.id); else set.delete(a.id);
        state.owned = [...set];
        if (state.onlyOwned) recalc(); else saveState();
      });
      rows.push(el('tr', { 'data-id': a.id, class: a.unobtainable ? 'unobtainable' : null },
        el('td', null, box),
        el('td', null, wikiLink(a, a.name, a.form ? el('span', { class: 'form' }, ' ' + a.form) : null),
          a.prismana ? el('span', { class: 'prismana' }, 'Prismana') : null,
          a.unobtainable ? el('span', { class: 'tag', title: 'No wild spawn, evolution or egg — never used in teams' }, 'Unobtainable') : null),
        el('td', null, a.elements.map(e => el('span', { class: `el ${abilityClass(e)}` }, icon(e), e))),
        el('td', null, Object.entries(a.abilities).sort((x, y) => y[1] - x[1]).map(([n, l]) => abilityBadge(n, l)))
      ));
    }
    tbody.replaceChildren(...rows);
    $('#roster-count').textContent = `${rows.length} of ${DATA.aniimo.length}`;
  }

  function setOwnedForShown(own) {
    const set = new Set(state.owned);
    document.querySelectorAll('#aniimo-table tbody tr').forEach(tr => {
      if (own) set.add(tr.dataset.id); else set.delete(tr.dataset.id);
    });
    state.owned = [...set];
    renderRoster();
    recalc();
  }

  // ---------- Solving ----------

  function pool(includePrismana) {
    const owned = new Set(state.owned);
    return DATA.aniimo.filter(a => !a.unobtainable &&
      (includePrismana || !a.prismana) && (!state.onlyOwned || owned.has(a.id)));
  }

  function activeRequirements() {
    return DATA.abilities
      .filter(ab => state.needs[ab] && state.needs[ab].on)
      .map(ab => ({ ability: ab, minLevel: state.needs[ab].minLevel, count: state.needs[ab].count }));
  }

  function run(reqs, includePrismana) {
    return AniimoSolver.solve(pool(includePrismana), reqs, {
      maxCount: state.maxCount,
      multiRole: state.multiRole,
      allowDuplicates: state.allowDupes,
    });
  }

  let timer = null;
  function recalc() {
    saveState();
    clearTimeout(timer);
    timer = setTimeout(renderResult, 60);
  }

  function renderResult() {
    const out = $('#result');
    const reqs = activeRequirements();
    if (!reqs.length) {
      out.replaceChildren(el('p', { class: 'muted' }, 'Tick at least one ability above.'));
      return;
    }

    const res = run(reqs, state.allowPrismana);
    // When Prismana is off, check whether turning it on would help.
    const withP = state.allowPrismana ? null : run(reqs, true);
    const nodes = [];

    if (res.status === 'unfillable') {
      const items = res.unfillable.length ? res.unfillable : reqs.map(r => ({ ...r, available: null }));
      nodes.push(el('p', { class: 'bad' }, 'These needs can’t be filled with the current settings:'));
      nodes.push(el('ul', null, items.map(u => {
        const prismanaFix = withP && !withP.unfillable.some(x => x.ability === u.ability) &&
          (withP.status !== 'unfillable' || withP.unfillable.length > 0);
        return el('li', null,
          `${u.ability} Lv ${u.minLevel}+ × ${u.count}`,
          u.available ? ` — only ${u.available} different Aniimo qualify` : ' — no Aniimo qualifies',
          prismanaFix ? el('span', { class: 'hint' }, ' · only reachable with Prismana forms — enable “Allow Prismana forms” to use') : null,
          state.onlyOwned ? el('span', { class: 'hint' }, ' · you’re limited to Aniimo you own') : null);
      })));
      out.replaceChildren(...nodes);
      return;
    }

    if (res.status === 'over-max') {
      nodes.push(el('p', { class: 'bad' },
        `You need at least ${res.count} Aniimo for this, but your max is ${res.maxCount}. Here’s the smallest team anyway:`));
    } else {
      nodes.push(el('p', { class: 'good' },
        `${res.count} Aniimo cover everything`, el('span', { class: 'muted' }, ` (total level ${res.score}, max ${res.maxCount})`)));
    }
    if (withP && withP.status !== 'unfillable' && withP.count < res.count) {
      nodes.push(el('p', { class: 'hint' }, `Allowing Prismana forms would bring this down to ${withP.count}.`));
    }
    if (!res.exact) {
      nodes.push(el('p', { class: 'hint' }, 'This is a very large request, so the search was stopped early. This is the best team found, but a smaller one might exist.'));
    } else if (!res.levelExact) {
      nodes.push(el('p', { class: 'hint' }, 'This is the smallest possible team. A same-size team with slightly higher levels might exist.'));
    }

    nodes.push(el('ol', { class: 'team' }, res.team.map(t =>
      el('li', null,
        el('div', { class: 'who' },
          el('strong', null, wikiLink(t.aniimo, displayName(t.aniimo))),
          t.copies > 1 ? el('span', { class: 'copies' }, `× ${t.copies}`) : null,
          t.aniimo.prismana ? el('span', { class: 'prismana' }, 'Prismana') : null),
        el('div', { class: 'fills' }, 'Fills: ', t.fills.map(f => abilityBadge(f.ability, f.level))))
    )));
    out.replaceChildren(...nodes);
  }

  // ---------- Wiring ----------

  function bindSettings() {
    const bind = (id, key, kind) => {
      const input = $(id);
      if (kind === 'check') input.checked = state[key]; else input.value = state[key];
      input.addEventListener(kind === 'check' ? 'change' : 'input', () => {
        state[key] = kind === 'check' ? input.checked : Math.max(1, +input.value || 1);
        recalc();
      });
    };
    bind('#max-count', 'maxCount', 'number');
    bind('#allow-prismana', 'allowPrismana', 'check');
    bind('#only-owned', 'onlyOwned', 'check');
    bind('#multi-role', 'multiRole', 'check');
    bind('#allow-dupes', 'allowDupes', 'check');

    const showP = $('#show-prismana');
    showP.checked = state.showPrismana;
    showP.addEventListener('change', () => { state.showPrismana = showP.checked; saveState(); renderRoster(); });

    $('#search').addEventListener('input', renderRoster);
    $('#ability-filter').addEventListener('change', renderRoster);
    $('#own-shown').addEventListener('click', () => setOwnedForShown(true));
    $('#unown-shown').addEventListener('click', () => setOwnedForShown(false));
    $('#reset-needs').addEventListener('click', () => { state.needs = {}; renderNeeds(); recalc(); });
  }

  async function init() {
    const iconsReady = AniimoIcons.loadOfficial();
    try {
      const res = await fetch('data/aniimo.json');
      DATA = await res.json();
      await iconsReady;
    } catch (e) {
      $('#result').replaceChildren(el('p', { class: 'bad' }, 'Could not load the Aniimo list. Please reload the page.'));
      return;
    }
    $('#data-date').textContent = `updated ${DATA.generated}`;
    // Links from the ability pages (/?need=Perfumery) tick that ability.
    const linked = new URLSearchParams(location.search).get('need');
    if (DATA.abilities.includes(linked)) {
      needFor(linked).on = true;
      saveState();
      history.replaceState(null, '', location.pathname);
    }
    $('#ability-filter').append(...DATA.abilities.map(a => el('option', { value: a }, a)));
    bindSettings();
    renderNeeds();
    renderRoster();
    renderResult();
  }

  init();
})();
