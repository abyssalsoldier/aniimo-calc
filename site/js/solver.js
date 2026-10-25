// Homeland team solver.
//
// A requirement is { ability, minLevel, count }: "count different workers with
// `ability` at level >= minLevel". An Aniimo is { id, name, abilities: { Fire: 3, ... } }.
//
// Goal: fewest Aniimo that meet every requirement, ties broken by the highest
// total level in the required abilities.
//  - multiRole (default): one Aniimo counts toward every requirement it meets.
//    Exact branch-and-bound with linear-programming lower bounds.
//  - single-role: each Aniimo fills one requirement, so the team size is fixed
//    and picking workers is an assignment problem (solved exactly with min-cost flow).
(function (root) {
  'use strict';

  const DEFAULTS = {
    multiRole: true,        // one Aniimo counts toward every requirement it meets
    allowDuplicates: true,  // the same species can be picked more than once
    timeLimitMs: 10000,     // safety net only; the result is flagged inexact if it runs out
    nodeLimit: 2000000,
  };

  function solve(aniimo, requirements, options) {
    const opt = Object.assign({}, DEFAULTS, options);
    const maxCount = opt.maxCount == null ? Infinity : opt.maxCount;
    const reqs = requirements.filter(r => r.count > 0);
    const needs0 = reqs.map(r => r.count);
    const sumNeeds = needs0.reduce((a, b) => a + b, 0);
    const empty = extra => Object.assign(
      { status: 'ok', team: [], count: 0, score: 0, maxCount, exact: true, levelExact: true, unfillable: [], nodes: 0 }, extra);

    if (reqs.length === 0) return empty();

    // Group Aniimo with identical levels in the required abilities into one "type".
    const typeByKey = new Map();
    for (const a of aniimo) {
      const lv = reqs.map(r => {
        const l = (a.abilities && a.abilities[r.ability]) || 0;
        return l >= r.minLevel ? l : 0;
      });
      if (!lv.some(l => l > 0)) continue;
      const key = lv.join(',');
      if (!typeByKey.has(key)) typeByKey.set(key, { lv, score: lv.reduce((s, l) => s + l, 0), members: [] });
      typeByKey.get(key).members.push(a);
    }
    let types = [...typeByKey.values()];
    for (const t of types) {
      t.members.sort((x, y) => (!!x.prismana - !!y.prismana) ||displayName(x).localeCompare(displayName(y)));
      t.cap = opt.allowDuplicates ? sumNeeds : Math.min(t.members.length, sumNeeds);
    }

    // Requirements no candidate (or not enough candidates) can meet.
    const unfillable = [];
    reqs.forEach((r, i) => {
      const available = types.reduce((s, t) => s + (t.lv[i] > 0 ? t.members.length : 0), 0);
      if (available === 0 || (!opt.allowDuplicates && available < r.count)) {
        unfillable.push({ ability: r.ability, minLevel: r.minLevel, count: r.count, available });
      }
    });
    if (unfillable.length) return empty({ status: 'unfillable', unfillable });

    const result = opt.multiRole
      ? searchMultiRole(types, needs0, sumNeeds, opt)
      : assignSingleRole(types, needs0);
    if (!result) return empty({ status: 'unfillable' });

    return {
      status: result.count > maxCount ? 'over-max' : 'ok',
      team: buildTeam(result.picks, reqs),
      count: result.count,
      score: result.score,
      maxCount,
      exact: result.exact,
      levelExact: result.levelExact,
      nodes: result.nodes || 0,
      unfillable: [],
    };
  }

  const displayName = a => a.form ? `${a.name} (${a.form})` : a.name;

  // ---------- multi-role: LP-based branch and bound ----------
  //
  // Integer program: pick x_t copies of each type t (0..cap_t) so every
  // requirement i gets sum_t [t meets i] * x_t >= need_i, minimising
  // sum_t (M - score_t) * x_t. With M bigger than any team's total level this
  // means "fewest Aniimo first, then highest level" in a single objective.
  // Each node solves the LP relaxation, which gives a tight lower bound, so
  // almost every branch is pruned straight away.

  function searchMultiRole(types, needs0, sumNeeds, opt) {
    types = removeDominated(types, sumNeeds);
    const T = types.length, R = needs0.length;
    const M = sumNeeds * Math.max(...types.map(t => t.score)) + 1;
    const cost = types.map(t => (M - t.score) / M); // scaled so one Aniimo ~ 1
    const now = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());
    const start = now();

    let best = null;     // { obj, picks: [type index...] }
    let nodes = 0;
    let exact = true;
    const left = types.map(t => t.cap);
    const picks = [];

    // Integer objective of a finished team: count * M - total level.
    const objOf = list => list.reduce((s, t) => s + M - types[t].score, 0);

    // Greedy team for an early upper bound: repeatedly take the type that
    // covers the most outstanding units per unit cost.
    (function greedy() {
      const needs = needs0.slice(), cap = left.slice(), team = [];
      for (;;) {
        let bestT = -1, bestRatio = 0;
        for (let t = 0; t < T; t++) {
          if (cap[t] <= 0) continue;
          let u = 0;
          for (let i = 0; i < R; i++) if (needs[i] > 0 && types[t].lv[i] > 0) u++;
          if (u / cost[t] > bestRatio) { bestRatio = u / cost[t]; bestT = t; }
        }
        if (bestT < 0) break;
        team.push(bestT);
        cap[bestT]--;
        for (let i = 0; i < R; i++) if (needs[i] > 0 && types[bestT].lv[i] > 0) needs[i]--;
        if (needs.every(n => n === 0)) {
          best = { obj: objOf(team), picks: team };
          break;
        }
      }
    })();

    function dfs(needs, objSoFar, lpState) {
      if (++nodes % 256 === 0 && (nodes > opt.nodeLimit || now() - start > opt.timeLimitMs)) {
        exact = false;
      }
      if (!exact) return;

      if (needs.every(n => n === 0)) {
        if (!best || objSoFar < best.obj) best = { obj: objSoFar, picks: picks.slice() };
        return;
      }

      const lp = solveLP(lpState, needs, left);
      if (lp === null) return; // nothing can cover what's left
      const bound = objSoFar + Math.ceil(lp.z * M - 1e-6);
      if (best && bound >= best.obj) return;

      // Find a fractional pick to branch on.
      let frac = -1, fracVal = -1;
      if (!lp.x) {
        // No LP solution to go on: branch on any type that still helps.
        frac = types.findIndex((ty, t) => left[t] > 0 && needs.some((n, i) => n > 0 && ty.lv[i] > 0));
        if (frac < 0) return;
      }
      for (let t = 0; lp.x && t < T; t++) {
        const f = lp.x[t] - Math.floor(lp.x[t] + 1e-9);
        if (f > 1e-6 && f < 1 - 1e-6 && lp.x[t] > fracVal) { frac = t; fracVal = lp.x[t]; }
      }
      if (frac < 0) {
        // LP optimum is already whole numbers: that's the best team for this branch.
        const team = picks.slice();
        for (let t = 0; t < T; t++) for (let k = Math.round(lp.x[t]); k > 0; k--) team.push(t);
        const obj = objSoFar + objOf(team.slice(picks.length));
        if (!best || obj < best.obj) best = { obj, picks: team };
        return;
      }

      // Reduced-cost fixing: an unused type whose reduced cost pushes the bound
      // past the best team found can't appear anywhere below this node.
      const fixed = [];
      if (best && lp.d) {
        for (let u = 0; u < T; u++) {
          if (left[u] > 0 && lp.x[u] < 1e-9 && lp.d[u] > 0 &&
              objSoFar + Math.ceil((lp.z + lp.d[u]) * M - 1e-6) >= best.obj) {
            fixed.push([u, left[u]]);
            left[u] = 0;
          }
        }
      }

      // Branch: take one more of `frac` now, or never take any more of it.
      const t = frac;
      const next = needs.slice();
      for (let i = 0; i < R; i++) if (next[i] > 0 && types[t].lv[i] > 0) next[i]--;
      left[t]--;
      picks.push(t);
      dfs(next, objSoFar + M - types[t].score, cloneLP(lpState));
      picks.pop();
      left[t]++;

      const saved = left[t];
      left[t] = 0;
      dfs(needs, objSoFar, lpState);
      left[t] = saved;

      for (const [u, n] of fixed) left[u] = n;
    }

    dfs(needs0.slice(), 0, createLP(types, cost, R));
    if (!best) return null;

    const count = best.picks.length;
    const score = count * M - best.obj;
    // Each pick counts toward every still-open requirement it meets.
    const remaining = needs0.slice();
    const out = best.picks.map(t => {
      const fills = [];
      for (let i = 0; i < R; i++) if (types[t].lv[i] > 0 && remaining[i] > 0) { remaining[i]--; fills.push(i); }
      return { type: types[t], fills };
    });
    return { count, score, exact, levelExact: exact, picks: out, nodes };
  }

  // LP relaxation: min sum c_t x_t  s.t.  sum_t a_it x_t >= need_i,
  // 0 <= x_t <= left_t, solved with a bounded-variable dual simplex.
  // x = 0 is dual feasible because every c_t > 0. Branching only changes
  // right-hand sides and upper bounds, which keeps the parent's final basis
  // dual feasible, so each child warm-starts from it and usually needs only a
  // pivot or two. There are at most 13 rows, so each pivot is cheap.

  function createLP(types, cost, R) {
    const T = types.length, n = T + R; // columns: x_0..x_T-1, surplus s_0..s_R-1
    // Row form: basic + sum_j tab[r][j] * x_j = rhs. Initially the surplus
    // s_r = sum_t a_rt x_t - need_r is basic: s_r - sum_t a_rt x_t = -need_r.
    const tab = [];
    for (let r = 0; r < R; r++) {
      const row = new Float64Array(n);
      for (let t = 0; t < T; t++) if (types[t].lv[r] > 0) row[t] = -1;
      row[T + r] = 1;
      tab.push(row);
    }
    const d = new Float64Array(n); // reduced costs
    for (let t = 0; t < T; t++) d[t] = cost[t];
    const basis = new Int32Array(R);
    const inBasis = new Uint8Array(n);
    for (let r = 0; r < R; r++) { basis[r] = T + r; inBasis[T + r] = 1; }
    return { T, R, n, cost, tab, d, basis, inBasis, atUpper: new Uint8Array(n), value: new Float64Array(n) };
  }

  function cloneLP(lp) {
    return Object.assign({}, lp, {
      tab: lp.tab.map(row => row.slice()),
      d: lp.d.slice(),
      basis: lp.basis.slice(),
      inBasis: lp.inBasis.slice(),
      atUpper: lp.atUpper.slice(),
      value: lp.value.slice(),
    });
  }

  // Re-optimise `lp` in place for new needs / upper bounds.
  // Returns { z, x, d }, or null if nothing can cover the needs.
  function solveLP(lp, needs, left) {
    const { T, R, n, cost, tab, d, basis, inBasis, atUpper, value } = lp;
    const EPS = 1e-9;
    const ub = j => (j < T ? left[j] : Infinity);

    // Nonbasic variables sit on a bound; basic ones follow from the tableau.
    // The surplus columns of the tableau hold B^-1, so rhs_r = sum_k tab[r][T+k] * -need_k.
    for (let j = 0; j < T; j++) {
      if (!inBasis[j]) value[j] = atUpper[j] ? left[j] : 0;
    }
    for (let r = 0; r < R; r++) {
      const row = tab[r];
      let v = 0;
      for (let k = 0; k < R; k++) v -= row[T + k] * needs[k];
      for (let j = 0; j < T; j++) if (!inBasis[j] && value[j] !== 0) v -= row[j] * value[j];
      value[basis[r]] = v;
    }

    for (let iter = 0; iter < 5000; iter++) {
      // Leaving row: the most infeasible basic variable.
      let r = -1, worst = 1e-7, below = true;
      for (let k = 0; k < R; k++) {
        const v = value[basis[k]];
        if (-v > worst) { worst = -v; r = k; below = true; }
        const over = v - ub(basis[k]);
        if (over > worst) { worst = over; r = k; below = false; }
      }
      if (r < 0) {
        let z = 0;
        const x = new Float64Array(T);
        for (let t = 0; t < T; t++) { x[t] = value[t]; z += cost[t] * value[t]; }
        return { z, x, d };
      }

      // Entering column: the ratio test keeps every reduced cost dual feasible.
      const row = tab[r];
      let q = -1, bestRatio = Infinity;
      for (let j = 0; j < n; j++) {
        if (inBasis[j] || ub(j) === 0) continue;
        const a = row[j];
        if (Math.abs(a) < EPS) continue;
        // Raising x_j from its lower bound moves the basic var by -a; lowering it from its upper bound by +a.
        const helps = below ? (atUpper[j] ? a > 0 : a < 0) : (atUpper[j] ? a < 0 : a > 0);
        if (!helps) continue;
        const ratio = Math.abs(d[j] / a);
        if (ratio < bestRatio - 1e-12) { bestRatio = ratio; q = j; }
      }
      if (q < 0) return null; // primal infeasible

      // Move the entering variable so the leaving one lands exactly on its bound.
      const leave = basis[r];
      const target = below ? 0 : ub(leave);
      const delta = (value[leave] - target) / row[q];
      for (let k = 0; k < R; k++) value[basis[k]] -= tab[k][q] * delta;
      value[q] += delta;
      value[leave] = target;
      atUpper[leave] = below ? 0 : 1;
      atUpper[q] = 0;

      // Pivot the tableau on (r, q).
      const p = row[q];
      for (let j = 0; j < n; j++) row[j] /= p;
      for (let k = 0; k < R; k++) {
        if (k === r) continue;
        const f = tab[k][q];
        if (f !== 0) {
          const rk = tab[k];
          for (let j = 0; j < n; j++) rk[j] -= f * row[j];
        }
      }
      const dq = d[q];
      for (let j = 0; j < n; j++) d[j] -= dq * row[j];
      basis[r] = q;
      inBasis[q] = 1;
      inBasis[leave] = 0;
    }
    return { z: 0, x: null }; // iteration cap hit: trivial (still valid) bound, no solution to use
  }

  // Drop a type if other types meeting every requirement it meets, at an equal or
  // higher level, can supply at least `needed` Aniimo. Swapping in one of those
  // never makes a team bigger or lower-levelled, and a team never needs more
  // than `needed` (= total workers asked for) Aniimo.
  function removeDominated(types, needed) {
    const dominates = (d, c) => d.lv.every((l, i) => l >= c.lv[i]);
    return types.filter(c => {
      let supply = 0;
      for (const d of types) {
        if (d === c || !dominates(d, c)) continue;
        supply += d.cap;
        if (supply >= needed) return false;
      }
      return true;
    });
  }

  // ---------- single-role: min-cost flow ----------
  // source -> requirement (capacity = workers needed) -> type (cost = -level) -> sink (capacity = copies)

  function assignSingleRole(types, needs0) {
    const R = needs0.length, T = types.length;
    const S = 0, sink = 1 + R + T, N = sink + 1;
    const graph = Array.from({ length: N }, () => []);
    const addEdge = (u, v, cap, cost) => {
      graph[u].push({ v, cap, cost, rev: graph[v].length });
      graph[v].push({ v: u, cap: 0, cost: -cost, rev: graph[u].length - 1 });
    };
    for (let i = 0; i < R; i++) addEdge(S, 1 + i, needs0[i], 0);
    for (let t = 0; t < T; t++) {
      for (let i = 0; i < R; i++) if (types[t].lv[i] > 0) addEdge(1 + i, 1 + R + t, needs0[i], -types[t].lv[i]);
      addEdge(1 + R + t, sink, types[t].cap, 0);
    }

    let flow = 0, cost = 0;
    const total = needs0.reduce((a, b) => a + b, 0);
    while (flow < total) {
      // Bellman-Ford (SPFA) shortest path; costs can be negative
      const dist = new Array(N).fill(Infinity), inQ = new Array(N).fill(false), prev = new Array(N);
      dist[S] = 0;
      const queue = [S];
      while (queue.length) {
        const u = queue.shift();
        inQ[u] = false;
        graph[u].forEach((e, idx) => {
          if (e.cap > 0 && dist[u] + e.cost < dist[e.v]) {
            dist[e.v] = dist[u] + e.cost;
            prev[e.v] = [u, idx];
            if (!inQ[e.v]) { inQ[e.v] = true; queue.push(e.v); }
          }
        });
      }
      if (dist[sink] === Infinity) break;
      let push = total - flow;
      for (let v = sink; v !== S; v = prev[v][0]) push = Math.min(push, graph[prev[v][0]][prev[v][1]].cap);
      for (let v = sink; v !== S; v = prev[v][0]) {
        const e = graph[prev[v][0]][prev[v][1]];
        e.cap -= push;
        graph[v][e.rev].cap += push;
      }
      flow += push;
      cost += push * dist[sink];
    }
    if (flow < total) return null;

    // Read the assignment off the requirement -> type edges.
    const picks = [];
    for (let i = 0; i < R; i++) {
      for (const e of graph[1 + i]) {
        if (e.v <= R || e.v === sink) continue;
        const usedFlow = graph[e.v][e.rev].cap; // reverse edge capacity = flow sent
        for (let k = 0; k < usedFlow; k++) picks.push({ type: types[e.v - 1 - R], fills: [i] });
      }
    }
    return { count: total, score: -cost, exact: true, levelExact: true, picks };
  }

  // ---------- result ----------

  // Turn type picks into named Aniimo, grouped, with the requirements each fills.
  function buildTeam(picks, reqs) {
    const nextMember = new Map(); // type -> index of next distinct member to hand out
    const byId = new Map();
    for (const { type, fills } of picks) {
      const k = nextMember.get(type) || 0;
      nextMember.set(type, k + 1);
      // different Aniimo first; once they run out (duplicates allowed), repeat the first
      const a = type.members[k < type.members.length ? k : 0];
      let entry = byId.get(a.id);
      if (!entry) {
        entry = { aniimo: a, copies: 0, fills: [] };
        byId.set(a.id, entry);
      }
      entry.copies++;
      for (const i of fills) {
        if (!entry.fills.some(f => f.ability === reqs[i].ability)) {
          entry.fills.push({ ability: reqs[i].ability, level: type.lv[i] });
        }
      }
    }
    return [...byId.values()];
  }

  const api = { solve };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.AniimoSolver = api;
})(typeof window !== 'undefined' ? window : globalThis);
