package graphl_compiler

import (
	"context"
	"errors"
	"fmt"
	"log"

	//"github.com/MichaelBelousov/graphl/lang-lib/lang-sdks/go/graphl_types"

	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/imports/wasi_snapshot_preview1"
)

type Val interface {
	tryU32() (uint32, error)
	// tryU64() (uint64, error)
	// tryI32() (int32, error)
	// tryI64() (int64, error)
	// tryF32() (float32, error)
	// tryF64() (float64, error)
	tryString() (string, error)

	getU32() uint32
	// getU64() uint64
	// getI32() int32
	// getI64() int64
	// getF32() float3
	// getF64() float64
	getString() string
}

type ValU32 uint32
type ValU64 uint64
type ValI32 int32
type ValI64 int64
type ValF32 float32
type ValF64 float64
type ValString string

func (val ValU32) getU32() uint32 { return uint32(val) }
func (val ValU32) tryU32() (uint32, error) { return uint32(val), nil }
func (val ValU32) getString() uint32 { panic(errors.New("tried to get string from u32")) }
func (val ValU32) tryString() (uint32, error) { return 0, errors.New("tried to get string from u32") }

type HostFuncCtx struct {
	args []Val
}

type HostEnv map[string]func(interface{}) interface{}

type Program struct {
}

func (p *Program) CallFunc() interface{} {
	var empty interface{}
	return empty
}

func CompileGraphltSource() {

}

func CompileGraphltSourceAndInstantiateProgram() {

}

func InstantiateProgramFromWasmBuffer(wasmBuff []byte) Program {
	ctx := context.Background()
	runtime := wazero.NewRuntime(ctx)
	defer runtime.Close(ctx)

	wasi_snapshot_preview1.MustInstantiate(ctx, runtime)
	cfg := wazero.NewModuleConfig().WithStartFunctions("_initialize")
	mod, err := runtime.InstantiateWithConfig(ctx, wasmBuff, cfg)
	if err != nil {
		log.Panicf("Failed to instantiate module: %v", err)
	}

	main := mod.ExportedFunction("main")
	results, err := main.Call(ctx)
	if err != nil {
		log.Panicf("call main failed: %v", err)
	}

	fmt.Printf("result: %v", results)

	return Program{}
}
