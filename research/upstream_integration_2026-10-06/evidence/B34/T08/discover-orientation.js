'use strict';
const ex = n => Module.getGlobalExportByName(n);
const classes = new NativeFunction(ex('objc_getClassList'), 'int', ['pointer', 'int']);
const classname = new NativeFunction(ex('class_getName'), 'pointer', ['pointer']);
const methods = new NativeFunction(ex('class_copyMethodList'), 'pointer', ['pointer', 'pointer']);
const methodname = new NativeFunction(ex('method_getName'), 'pointer', ['pointer']);
const selectorname = new NativeFunction(ex('sel_getName'), 'pointer', ['pointer']);
const encoding = new NativeFunction(ex('method_getTypeEncoding'), 'pointer', ['pointer']);
const free = new NativeFunction(ex('free'), 'void', ['pointer']);
rpc.exports = {
  inventory() {
    const count = classes(ptr(0), 0), buffer = Memory.alloc(count * Process.pointerSize);
    const actual = classes(buffer, count), result = [];
    for (let i = 0; i < Math.min(actual, count); i++) {
      const cls = buffer.add(i * Process.pointerSize).readPointer();
      const name = classname(cls).readUtf8String();
      if (!(name === 'UIWindowScene' || name === 'UIApplication' ||
            (/^(SB|FB|FBS)/.test(name) && /Orientation|Scene|Geometry/.test(name)))) continue;
      const size = Memory.alloc(4); size.writeU32(0);
      const list = methods(cls, size), found = [], typed = [];
      try {
        for (let j = 0; j < size.readU32(); j++) {
          const method = list.add(j * Process.pointerSize).readPointer();
          const selector = selectorname(methodname(method)).readUtf8String();
          if (/Orientation|Geometry/.test(name) || /orientation|geometry|clientSettings|updateSettings/i.test(selector)) {
            found.push(selector);
            typed.push({selector: selector, encoding: encoding(method).readUtf8String()});
          }
        }
      } finally { if (!list.isNull()) free(list); }
      if (found.length) result.push({class: name, methods: found, typed_methods: typed});
    }
    return {pid: Process.id, executable: Process.mainModule.name, classes: result};
  }
};
