function assert(condition: any, message?: string): asserts condition {
  if (!condition) throw Error(message ?? "AssertionError: condition was falsey");
}

type CompatibleWebAssemblyInstance = WebAssembly.Instance & {
  exports: {
    memory: WebAssembly.Memory;
    alloc_string(byte_count: number): number;
    free_string(ptr: number): void;
  }
}

interface Str {
  value: string;
  ptr: number;
  free(): void;
}

export function assertCompatibleWasmInstance(w: WebAssembly.Instance): asserts w is CompatibleWebAssemblyInstance {
  assert(w.exports.memory instanceof WebAssembly.Memory);
  assert(typeof w.exports.alloc_string === "function");
  assert(typeof w.exports.free_string === "function");
}

export function makeWasmHelper(wasmInst: WebAssembly.Instance) {
  assertCompatibleWasmInstance(wasmInst);

  return {
    ptrToStr(ptr: number, encoding?: string): Str {
      const slice = new Uint8Array(wasmInst.exports.memory.buffer.slice(ptr));
      let i = 0;
      for (; i < slice.byteLength; ++i) {
        if (slice[i] === 0) break;
      }
      return this.ptrAndLenToStr(ptr, i - 1, encoding);
    },

    ptrAndLenToStr(ptr: number, len: number, encoding = "utf8"): Str {
      const slice = wasmInst.exports.memory.buffer.slice(ptr, ptr + len);
      return {
        value: new TextDecoder(encoding).decode(slice),
        ptr,
        free(this: Str) { wasmInst.exports.free_string(this.ptr); },
      };
    },

    marshalString(str: string): Str {
      const strBytes = new TextEncoder().encode(str);
      const allocPtr = wasmInst.exports.alloc_string(strBytes.byteLength);
      const allocSlice = new DataView(wasmInst.exports.memory.buffer, allocPtr, strBytes.byteLength);
      for (let i = 0; i < strBytes.byteLength; ++i) {
        allocSlice.setUint8(i, strBytes[i]);
      }
      return this.ptrAndLenToStr(allocPtr, strBytes.byteLength);
    },
  }
}
