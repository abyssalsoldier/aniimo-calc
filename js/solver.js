// Homeland team solver.
//
// A requirement is { ability, minLevel, count }: "count different workers with
// `ability` at level >= minLevel". An Aniimo is { id, name, abilities: { Fire: 3, ... } }.
//
// Goal: fewest Aniimo that meet every requirement, ties broken by the highest
// total level in the required abilities.
//  - multiRole (default): one Aniimo counts toward every requirement it meets.
//    Exact branch-and-bound: first prove the minimum team size, then search
//    teams of that size for the highest total level.
//  - single-role: each Aniimo fills one requirement, so the team size is fixed
//    and picking workers is an assignment problem (solved exactly with min-cost flow).
(function (root) {
  'use strict';

  const DEFAULTS = {
    multiRole: true,        // one Aniimo counts toward every requirement it meets
    allowDuplicates: true,  // the same species can be picked more than once
    timeLimitMs: 2500,      // search budget; the result is flagged inexact if it runs out
    nodeLimit: 5000000,
  };

  function solve(aniimo, requirements, options) {
    const opt = Object.assign({}, DEFAULTS, options);
    const maxCount = opt.maxCount == null ? Infinity : opt.maxCount;
    const reqs = requirements.filter(r => r.count > 0);
    const needs0 = reqs.map(r => r.count);
    const sumNeeds = needs0.reduce((a, b) => a + b, 0);
    const empty = extra => Object.assign(
      { status: 'ok', team: [], count: 0, score: 0, maxCount, exact: true, levelExact: true, unfillable: [] }, extra);

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
      unfillable: [],
    };
  }

  const displayName = a => a.form ? `${a.name} (${a.form})` : a.name;

  // ---------- multi-role: branch and bound ----------

  function searchMultiRole(types, needs0, sumNeeds, opt) {
    types = removeDominated(types, sumNeeds);
    const maxGain = Math.max(...types.map(t => t.score));
    const R = needs0.length;

    // Fewest Aniimo that could still cover what's left: k Aniimo reduce the
    // outstanding units by at most the sum of the k biggest coverages available.
    function lowerBound(needs, used) {
      let maxNeed = 0, units = 0;
      for (const n of needs) { if (n > maxNeed) maxNeed = n; units += n; }
      if (units === 0) return 0;
      const covers = [];
      for (let t = 0; t < types.length; t++) {
        const left = types[t].cap - used[t];
        if (left <= 0) continue;
        let c = 0;
        for (let i = 0; i < R; i++) if (needs[i] > 0 && types[t].lv[i] > 0) c++;
        if (c > 0) covers.push([c, left]);
      }
      covers.sort((x, y) => y[0] - x[0]);
      let k = 0, covered = 0;
      for (const [c, left] of covers) {
        const take = Math.min(left, Math.ceil((units - covered) / c));
        k += take;
        covered += take * c;
        if (covered >= units) return Math.max(maxNeed, k);
      }
      return Infinity;
    }

    let best = null;
    let exact = true;       // smallest team size is proven
    let levelExact = true;  // highest level at that size is proven
    const now = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());
    const start = now();
    let nodes = 0;
    let stopped = false;
    // Finding the size gets most of the budget; the level tie-break gets the rest.
    const outOfBudget = phase => {
      if (++nodes > opt.nodeLimit) return true;
      if ((nodes & 1023) !== 0) return false;
      return now() - start > opt.timeLimitMs * (phase === 'count' ? 0.8 : 1);
    };

    // phase 'count': find the smallest team. phase 'score': best level at that size.
    function run(phase) {
      stopped = false;
      const seen = new Set();
      const used = new Array(types.length).fill(0);
      const picks = [];

      function dfs(needs, count, score) {
        if (stopped || outOfBudget(phase)) {
          stopped = true;
          if (phase === 'count') exact = false;
          levelExact = false;
          return;
        }

        let r = -1, rOptions = null;
        for (let i = 0; i < R; i++) {
          if (needs[i] === 0) continue;
          const list = [];
          for (let t = 0; t < types.length; t++) {
            if (types[t].lv[i] > 0 && used[t] < types[t].cap) list.push(t);
          }
          if (rOptions === null || list.length < rOptions.length) { r = i; rOptions = list; }
        }
        if (r === -1) {
          if (!best || count < best.count || (count === best.count && score > best.score)) {
            best = { count, score, picks: picks.slice() };
          }
          return;
        }
        if (rOptions.length === 0) return;

        const lb = count + lowerBound(needs, used);
        if (best) {
          if (phase === 'count' ? lb >= best.count : lb > best.count) return;
          if (phase === 'score' && score + (best.count - count) * maxGain <= best.score) return;
        }

        const key = used.join(',');
        if (seen.has(key)) return;
        seen.add(key);

        const useful = t => {
          let u = 0;
          for (let i = 0; i < R; i++) if (needs[i] > 0 && types[t].lv[i] > 0) u++;
          return u;
        };
        rOptions
          .map(t => ({ t, u: useful(t) }))
          .sort((x, y) => y.u - x.u || types[y.t].score - types[x.t].score)
          .some(({ t }) => {
            const next = needs.slice();
            for (let i = 0; i < R; i++) if (next[i] > 0 && types[t].lv[i] > 0) next[i]--;
            used[t]++;
            picks.push(types[t]);
            dfs(next, count + 1, score + types[t].score);
            picks.pop();
            used[t]--;
            return stopped;
          });
      }

      dfs(needs0.slice(), 0, 0);
    }

    run('count');
    if (!best) return null;
    run('score');

    // In multi-role mode every pick counts toward each requirement it meets.
    const remaining = needs0.slice();
    const picks = best.picks.map(t => {
      const fills = [];
      for (let i = 0; i < R; i++) if (t.lv[i] > 0 && remaining[i] > 0) { remaining[i]--; fills.push(i); }
      return { type: t, fills };
    });
    return { count: best.count, score: best.score, exact, levelExact, picks };
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
