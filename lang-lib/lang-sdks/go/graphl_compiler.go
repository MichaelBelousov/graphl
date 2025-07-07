package graphl_compiler

import (
  "context"
  "errors"
  "fmt"
  "log"
  "strconv"

	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/imports/wasi_snapshot_preview1"
)

type ValU32 struct { val uint32 }
type ValU64 struct { val uint64 }
type ValI32 struct { val int32 }
type ValI64 struct { val int64 }
type ValF32 struct { val float32 }
type ValF64 struct { val float64 }
type ValString struct { val String }

type Val interface {
	tryU32() (uint32, Error)
	tryU64() (uint64, Error)
	tryI32() (int32, Error)
	tryI64() (int64, Error)
	tryF32() (float32, Error)
	tryF64() (float64, Error)
	tryString() (string, Error)

	getU32() uint32
	getU64() uint64
	getI32() int32
	getI64() int64
	getF32() float3
	getF64() float64
	getString() string
}

type TypeKind int32

// FIXME: how to enum in go?
const (
	TypeKindPrimitive GraphlType = 0
	TypeKindStruct               = 1
)

type TypeInfo struct {
	name string
	kind TypeKind
}

const (
	TypeVoid TypeInfo
)
// Types = {
    // export const void_: GraphlType = { name: "void", kind: "primitive", size: 0 };
    // export const i32: GraphlType = { name: "i32", kind: "primitive", size: 4 };
    // export const u32: GraphlType = { name: "u32", kind: "primitive", size: 4 };
    // export const i64: GraphlType = { name: "i64", kind: "primitive", size: 8 };
    // export const u64: GraphlType = { name: "u64", kind: "primitive", size: 8 };
    // export const bool: GraphlType = { name: "bool", kind: "primitive", size: 4 };
    // export const f32: GraphlType = { name: "f32", kind: "primitive", size: 4 };
    // export const f64: GraphlType = { name: "f64", kind: "primitive", size: 8 };
    // // FIXME: is this really a primtive? bad name
    // export const string: GraphlType = { name: "string", kind: "primitive", size: 4 };
    // export const code: GraphlType = { name: "string", kind: "primitive", size: 0 };
    // export const rgba: GraphlType = { name: "rgba", kind: "primitive", size: 4 };
    // export const extern: GraphlType = { name: "extern", kind: "primitive", size: 4 };

    // // TODO: parse structs out of graphl meta section
    // // of graphl output
    // export const vec3: GraphlType = {
    //     name: "vec3",
    //     kind: "struct",
    //     size: 24,
    //     fieldNames: ["x", "y", "z"],
    //     fieldTypes: [f64, f64, f64],
    //     fieldOffsets: [0, 8, 16],
    // };
// }


func getU32() {
	switch v := val.(type) {
	case GraphlValU32: return v.val
	default: return errors.New("not a u32")
	}
}

type HostFuncCtx struct {
	args: []GraphlVal
}

type HostEnv map[string]func (*void) *void

type Program struct {

}

func (p *Program) CallFunc() *void {

}

func CompileGraphltSource() {

}

func CompileGraphltSourceAndInstantiateProgram() {

}

func InstantiateProgramFromWasmBuffer() {

}
