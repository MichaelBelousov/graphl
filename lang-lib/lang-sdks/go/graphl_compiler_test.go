package graphl_compiler

import (
	"testing"
)

func Test_basicSdk() {
	program := CompileGraphltSourceAndInstantiateProgram(`

	`)
	program.CallFunc("hello")
}
