// 仅允许受控应用场景参与者的临时反事实实验；默认只读。
let gateOverride = false, gateRows = [], gateMarker = '';
const gateSpecs = ['_isAllowedToHavePortraitUpsideDown', '_allLegalOrientations', '_sanitizedMask:forApplication:', '_supportedOrientations'];
for (const selector of gateSpecs) {
  const method = cm(C('SBTraitsSceneParticipantDelegate'), S(selector));
  if (method.isNull()) throw Error('missing ' + selector);
  Interceptor.attach(imp(method).strip(), {
    onEnter(args) {
      this.receiver = desc(args[0]);
      this.scoped = this.receiver.includes('research.vphone.b31.rotation');
      this.input = selector === '_sanitizedMask:forApplication:' ? args[2].toInt32() : null;
    },
    onLeave(result) {
      if (!this.scoped) return;
      const native = result.toInt32();
      if (gateOverride && selector === '_isAllowedToHavePortraitUpsideDown') result.replace(1);
      if (gateRows.length < 3000) gateRows.push({marker: gateMarker, time: Date.now()/1000,
        selector, receiver: this.receiver, input: this.input, native, returned: result.toInt32(), override: gateOverride});
    }
  });
}
rpc.exports.gatebegin = (marker, enabled) => { gateMarker = marker; gateRows = []; gateOverride = enabled; return true; };
rpc.exports.gateend = () => gateRows;
rpc.exports.gaterestore = () => { gateOverride = false; return true; };
