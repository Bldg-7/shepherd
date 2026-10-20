// The name the app's Rename Pane gave this launch's pane, for Pi's session
// (SHPHRD-95). It arrives in the bridge's status replies (`pi-host.mjs`) as
// {sequence, name}, numbered by the app; each number is set once, with Pi's
// own extension API, while Pi is idle: nothing is typed into Pi. A number not
// set yet waits for agent_settled; a newer one replaces it. A new session
// drops a name not set yet: it was meant for the session before.
const LINE_BREAK_OR_CONTROL = /[\p{Cc}\u2028\u2029]/u;
const LIMIT = 200;
const characters = name => {
  try { return [...new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(name)].length; }
  catch { return [...name].length; }
};
const acceptable = value => !!value && Number.isSafeInteger(value.sequence) && value.sequence > 0 &&
  typeof value.name === 'string' && value.name !== '' && value.name === value.name.trim() &&
  !LINE_BREAK_OR_CONTROL.test(value.name) && characters(value.name) <= LIMIT;

export function registerPiSessionNaming(pi) {
  let offered, applied = 0, context, busy = true;
  const idle = ctx => {
    try { return ctx.isIdle() === true && ctx.hasPendingMessages() === false; } catch { return false; }
  };
  function apply() {
    if (!offered || busy || !context || !idle(context)) return;
    const { sequence, name } = offered;
    offered = undefined; applied = sequence;
    // Once for each number, whatever Pi makes of it.
    try { pi.setSessionName(name); } catch {}
  }
  const tui = handler => (_event, ctx) => { if (ctx?.mode === 'tui') handler(ctx); };
  pi.on('session_start', tui(ctx => { context = ctx; offered = undefined; busy = !idle(ctx); }));
  pi.on('agent_start', tui(ctx => { context = ctx; busy = true; }));
  pi.on('agent_settled', tui(ctx => { context = ctx; busy = !idle(ctx); apply(); }));
  pi.on('session_shutdown', () => { context = undefined; offered = undefined; busy = true; });
  return Object.freeze({
    offer(value) {
      if (!acceptable(value) || value.sequence <= applied || (offered && value.sequence <= offered.sequence)) return;
      offered = { sequence: value.sequence, name: value.name };
      apply();
    },
  });
}
