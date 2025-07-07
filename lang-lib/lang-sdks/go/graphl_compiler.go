package graphl_compiler

import (
	"context"
	"errors"
	"fmt"
	"log"
	"strconv"

	"github.com/MichaelBelousov/graphl/lang-lib/lang-sdks/go/graphl_types"

	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/imports/wasi_snapshot_preview1"
)

type ValU32 struct{ val uint32 }
type ValU64 struct{ val uint64 }
type ValI32 struct{ val int32 }
type ValI64 struct{ val int64 }
type ValF32 struct{ val float32 }
type ValF64 struct{ val float64 }
type ValString struct{ val String }

type Val interface {
	tryU32() (uint32, Error)
	// tryU64() (uint64, Error)
	// tryI32() (int32, Error)
	// tryI64() (int64, Error)
	// tryF32() (float32, Error)
	// tryF64() (float64, Error)
	// tryString() (string, Error)

	getU32() uint32
	// getU64() uint64
	// getI32() int32
	// getI64() int64
	// getF32() float3
	// getF64() float64
	// getString() string
}

func (val *Val) getU32() uint32 {
	switch v := val.(type) {
	case ValU32:
		return v.val
	default:
		panic("value was not a u32")
	}
}

func (val *Val) tryU32() (uin32, Error) {
	switch v := val.(type) {
	case ValU32:
		return v.val
	default:
		return Error("value was not a u32")
	}
}

type HostFuncCtx struct {
	args []Val
}

type HostEnv map[string]func(*void) *void

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
