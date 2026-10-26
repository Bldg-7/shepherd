// Proxy capture has a narrower proof than browser/MCP allocation. The native
// bridge authenticates the prepared root Pi identity without creating a lease;
// only that acknowledgement can label this TUI session.
export function createPiCaptureProof(nativeHost, capture, { proxyEnabled = false } = {}) {
  let generation = 0;
  const acknowledge = (identity, signal) => {
    if (!proxyEnabled || typeof nativeHost?.acknowledgeCapture !== 'function') return;
    const expectedGeneration = generation;
    void Promise.resolve(nativeHost.acknowledgeCapture(identity, signal)).then(acknowledged => {
      // A proof which arrives after TUI replacement/shutdown belongs to the
      // old generation and cannot restore its capture label.
      if (acknowledged === true && generation === expectedGeneration) capture.qualify(identity?.sessionID);
    }, () => {});
  };
  return Object.freeze({
    reset() {
      generation++;
      capture.clear();
    },
    acknowledge,
    open(identity, signal, open) {
      acknowledge(identity, signal);
      return open();
    },
  });
}
