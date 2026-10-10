// 拼接在 B32 fixture-policy.js 后；本探针不修改返回值。
const argCount = new NativeFunction(exp('method_getNumberOfArguments'), 'uint', ['pointer']);
const argType = new NativeFunction(exp('method_copyArgumentType'), 'pointer', ['pointer', 'uint']);
const returnType = new NativeFunction(exp('method_copyReturnType'), 'pointer', ['pointer']);
const releaseType = new NativeFunction(exp('free'), 'void', ['pointer']);
let boundaryEvents = [], boundaryHooks = [], boundaryEnabled = false, boundaryMarker = '', boundarySeq = 0;
function typeString(pointer) { try { return pointer.readUtf8String(); } finally { releaseType(pointer); } }
function valueFor(pointer, type) {
  if (type === '@?') return {block: pointer.toString()};
  if (type.startsWith('@')) {
    if (pointer.isNull()) return null;
    try { return {pointer: pointer.toString(), description: (desc(pointer) || '').slice(0, 16000)}; }
    catch (e) { return {pointer: pointer.toString(), description_error: String(e)}; }
  }
  if (/^[qQiIlLsScCB]/.test(type)) return pointer.toInt32();
  return {pointer: pointer.toString(), type: type, decoded: false};
}
function appendBoundary(row) {
  if (boundaryEvents.length < 5000) boundaryEvents.push(row);
}
function installBoundary(className, selector) {
  const m = cm(C(className), S(selector));
  if (m.isNull()) return {class: className, selector: selector, missing: true};
  const types = []; for (let i = 2; i < argCount(m); i++) types.push(typeString(argType(m, i)));
  const resultType = typeString(returnType(m)), address = imp(m).strip();
  const hook = Interceptor.attach(address, {
    onEnter(args) {
      this.record = boundaryEnabled;
      if (!this.record) return;
      this.seq = ++boundarySeq;
      this.errorPointers = types.map((t, i) => t === 'o^@' ? args[i + 2] : null);
      const row = {seq: this.seq, marker: boundaryMarker, time: Date.now() / 1000,
                   pid: Process.id, edge: 'enter', class: className, selector: selector,
                   receiver: valueFor(args[0], '@'), args: types.map((t, i) => valueFor(args[i + 2], t))};
      if (className === 'SBTraitsSceneOrientationRequestsAssistant') {
        row.traits_delegate = valueFor(get(args[0], 'traitsDelegate'), '@');
      }
      appendBoundary(row);
    },
    onLeave(result) {
      if (!this.record) return;
      appendBoundary({seq: this.seq, marker: boundaryMarker, time: Date.now() / 1000,
                      pid: Process.id, edge: 'leave', class: className, selector: selector,
                      result: resultType === 'v' ? null : valueFor(result, resultType),
                      errors: this.errorPointers.map(p => {
                        if (p === null || p.isNull()) return null;
                        try { return valueFor(p.readPointer(), '@'); } catch (e) { return {error: String(e)}; }
                      })});
    }
  });
  boundaryHooks.push(hook);
  return {class: className, selector: selector, address: address.toString(), args: types, result: resultType};
}
rpc.exports.tracearm = specifications => specifications.map(s => installBoundary(s[0], s[1]));
rpc.exports.tracebegin = marker => { boundaryMarker = marker; boundaryEvents = []; boundaryEnabled = true; return true; };
rpc.exports.traceend = () => { boundaryEnabled = false; return boundaryEvents; };
