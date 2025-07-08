package graphl_compiler

// #cgo CFLAGS: -g -Wall
// #include "../c/graphl.h"
import "C"
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
	tryU64() (uint64, error)
	tryI32() (int32, error)
	tryI64() (int64, error)
	tryF32() (float32, error)
	tryF64() (float64, error)
	tryString() (string, error)

	getU32() uint32
	getU64() uint64
	getI32() int32
	getI64() int64
	getF32() float32
	getF64() float64
	getString() string
}

type ValU32 uint32
type ValU64 uint64
type ValI32 int32
type ValI64 int64
type ValF32 float32
type ValF64 float64
type ValString string

// vim: r! ./graphl_compiler_codegen.py

func(val ValU32) getU32() uint32 { return uint32(val) }
func(val ValU32) tryU32() (uint32, error) { return uint32(val), nil }
func(val ValU32) getU64() uint32 { panic(errors.New("tried to get U64 from U32")) }
func(val ValU32) tryU64() (uint32, error) { return 0, errors.New("tried to get U64 from U32") }
func(val ValU32) getI32() uint32 { panic(errors.New("tried to get I32 from U32")) }
func(val ValU32) tryI32() (uint32, error) { return 0, errors.New("tried to get I32 from U32") }
func(val ValU32) getI64() uint32 { panic(errors.New("tried to get I64 from U32")) }
func(val ValU32) tryI64() (uint32, error) { return 0, errors.New("tried to get I64 from U32") }
func(val ValU32) getF32() uint32 { panic(errors.New("tried to get F32 from U32")) }
func(val ValU32) tryF32() (uint32, error) { return 0, errors.New("tried to get F32 from U32") }
func(val ValU32) getF64() uint32 { panic(errors.New("tried to get F64 from U32")) }
func(val ValU32) tryF64() (uint32, error) { return 0, errors.New("tried to get F64 from U32") }
func(val ValU32) getString() uint32 { panic(errors.New("tried to get String from U32")) }
func(val ValU32) tryString() (uint32, error) { return 0, errors.New("tried to get String from U32") }

func(val ValU64) getU32() uint64 { panic(errors.New("tried to get U32 from U64")) }
func(val ValU64) tryU32() (uint64, error) { return 0, errors.New("tried to get U32 from U64") }
func(val ValU64) getU64() uint64 { return uint64(val) }
func(val ValU64) tryU64() (uint64, error) { return uint64(val), nil }
func(val ValU64) getI32() uint64 { panic(errors.New("tried to get I32 from U64")) }
func(val ValU64) tryI32() (uint64, error) { return 0, errors.New("tried to get I32 from U64") }
func(val ValU64) getI64() uint64 { panic(errors.New("tried to get I64 from U64")) }
func(val ValU64) tryI64() (uint64, error) { return 0, errors.New("tried to get I64 from U64") }
func(val ValU64) getF32() uint64 { panic(errors.New("tried to get F32 from U64")) }
func(val ValU64) tryF32() (uint64, error) { return 0, errors.New("tried to get F32 from U64") }
func(val ValU64) getF64() uint64 { panic(errors.New("tried to get F64 from U64")) }
func(val ValU64) tryF64() (uint64, error) { return 0, errors.New("tried to get F64 from U64") }
func(val ValU64) getString() uint64 { panic(errors.New("tried to get String from U64")) }
func(val ValU64) tryString() (uint64, error) { return 0, errors.New("tried to get String from U64") }

func(val ValI32) getU32() int32 { panic(errors.New("tried to get U32 from I32")) }
func(val ValI32) tryU32() (int32, error) { return 0, errors.New("tried to get U32 from I32") }
func(val ValI32) getU64() int32 { panic(errors.New("tried to get U64 from I32")) }
func(val ValI32) tryU64() (int32, error) { return 0, errors.New("tried to get U64 from I32") }
func(val ValI32) getI32() int32 { return int32(val) }
func(val ValI32) tryI32() (int32, error) { return int32(val), nil }
func(val ValI32) getI64() int32 { panic(errors.New("tried to get I64 from I32")) }
func(val ValI32) tryI64() (int32, error) { return 0, errors.New("tried to get I64 from I32") }
func(val ValI32) getF32() int32 { panic(errors.New("tried to get F32 from I32")) }
func(val ValI32) tryF32() (int32, error) { return 0, errors.New("tried to get F32 from I32") }
func(val ValI32) getF64() int32 { panic(errors.New("tried to get F64 from I32")) }
func(val ValI32) tryF64() (int32, error) { return 0, errors.New("tried to get F64 from I32") }
func(val ValI32) getString() int32 { panic(errors.New("tried to get String from I32")) }
func(val ValI32) tryString() (int32, error) { return 0, errors.New("tried to get String from I32") }

func(val ValI64) getU32() int64 { panic(errors.New("tried to get U32 from I64")) }
func(val ValI64) tryU32() (int64, error) { return 0, errors.New("tried to get U32 from I64") }
func(val ValI64) getU64() int64 { panic(errors.New("tried to get U64 from I64")) }
func(val ValI64) tryU64() (int64, error) { return 0, errors.New("tried to get U64 from I64") }
func(val ValI64) getI32() int64 { panic(errors.New("tried to get I32 from I64")) }
func(val ValI64) tryI32() (int64, error) { return 0, errors.New("tried to get I32 from I64") }
func(val ValI64) getI64() int64 { return int64(val) }
func(val ValI64) tryI64() (int64, error) { return int64(val), nil }
func(val ValI64) getF32() int64 { panic(errors.New("tried to get F32 from I64")) }
func(val ValI64) tryF32() (int64, error) { return 0, errors.New("tried to get F32 from I64") }
func(val ValI64) getF64() int64 { panic(errors.New("tried to get F64 from I64")) }
func(val ValI64) tryF64() (int64, error) { return 0, errors.New("tried to get F64 from I64") }
func(val ValI64) getString() int64 { panic(errors.New("tried to get String from I64")) }
func(val ValI64) tryString() (int64, error) { return 0, errors.New("tried to get String from I64") }

func(val ValF32) getU32() float32 { panic(errors.New("tried to get U32 from F32")) }
func(val ValF32) tryU32() (float32, error) { return 0, errors.New("tried to get U32 from F32") }
func(val ValF32) getU64() float32 { panic(errors.New("tried to get U64 from F32")) }
func(val ValF32) tryU64() (float32, error) { return 0, errors.New("tried to get U64 from F32") }
func(val ValF32) getI32() float32 { panic(errors.New("tried to get I32 from F32")) }
func(val ValF32) tryI32() (float32, error) { return 0, errors.New("tried to get I32 from F32") }
func(val ValF32) getI64() float32 { panic(errors.New("tried to get I64 from F32")) }
func(val ValF32) tryI64() (float32, error) { return 0, errors.New("tried to get I64 from F32") }
func(val ValF32) getF32() float32 { return float32(val) }
func(val ValF32) tryF32() (float32, error) { return float32(val), nil }
func(val ValF32) getF64() float32 { panic(errors.New("tried to get F64 from F32")) }
func(val ValF32) tryF64() (float32, error) { return 0, errors.New("tried to get F64 from F32") }
func(val ValF32) getString() float32 { panic(errors.New("tried to get String from F32")) }
func(val ValF32) tryString() (float32, error) { return 0, errors.New("tried to get String from F32") }

func(val ValF64) getU32() float64 { panic(errors.New("tried to get U32 from F64")) }
func(val ValF64) tryU32() (float64, error) { return 0, errors.New("tried to get U32 from F64") }
func(val ValF64) getU64() float64 { panic(errors.New("tried to get U64 from F64")) }
func(val ValF64) tryU64() (float64, error) { return 0, errors.New("tried to get U64 from F64") }
func(val ValF64) getI32() float64 { panic(errors.New("tried to get I32 from F64")) }
func(val ValF64) tryI32() (float64, error) { return 0, errors.New("tried to get I32 from F64") }
func(val ValF64) getI64() float64 { panic(errors.New("tried to get I64 from F64")) }
func(val ValF64) tryI64() (float64, error) { return 0, errors.New("tried to get I64 from F64") }
func(val ValF64) getF32() float64 { panic(errors.New("tried to get F32 from F64")) }
func(val ValF64) tryF32() (float64, error) { return 0, errors.New("tried to get F32 from F64") }
func(val ValF64) getF64() float64 { return float64(val) }
func(val ValF64) tryF64() (float64, error) { return float64(val), nil }
func(val ValF64) getString() float64 { panic(errors.New("tried to get String from F64")) }
func(val ValF64) tryString() (float64, error) { return 0, errors.New("tried to get String from F64") }

func(val ValString) getU32() string { panic(errors.New("tried to get U32 from String")) }
func(val ValString) tryU32() (string, error) { return "", errors.New("tried to get U32 from String") }
func(val ValString) getU64() string { panic(errors.New("tried to get U64 from String")) }
func(val ValString) tryU64() (string, error) { return "", errors.New("tried to get U64 from String") }
func(val ValString) getI32() string { panic(errors.New("tried to get I32 from String")) }
func(val ValString) tryI32() (string, error) { return "", errors.New("tried to get I32 from String") }
func(val ValString) getI64() string { panic(errors.New("tried to get I64 from String")) }
func(val ValString) tryI64() (string, error) { return "", errors.New("tried to get I64 from String") }
func(val ValString) getF32() string { panic(errors.New("tried to get F32 from String")) }
func(val ValString) tryF32() (string, error) { return "", errors.New("tried to get F32 from String") }
func(val ValString) getF64() string { panic(errors.New("tried to get F64 from String")) }
func(val ValString) tryF64() (string, error) { return "", errors.New("tried to get F64 from String") }
func(val ValString) getString() string { return string(val) }
func(val ValString) tryString() (string, error) { return string(val), nil }

type HostFuncCtx struct {
	args []Val
}

type HostEnv map[string]func(interface{}) interface{}

type Program struct {
}

type NoSuchFuncError struct {
	funcName string
}
func (err *NoSuchFuncError) Error() string {
	return fmt.Sprintf("No such function: %s", err.funcName)
}


func (p *Program) CallFunc(name string, args ...Val) (Val, error) {
	return nil, errors.New("not implemented")
}

type CompileError struct {}
func (err *CompileError) Error() string {
	return "Compile Error"
}

func CompileGraphltSource() {

}

func CompileGraphltSourceAndInstantiateProgram(source string) (Program, error) {
	return Program{}, nil
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
