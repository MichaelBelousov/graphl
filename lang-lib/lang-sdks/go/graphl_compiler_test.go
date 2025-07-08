package graphl_compiler

import (
	"testing"
	"fmt"
)

func TestBasicSdk(t *testing.T) {
	program, err := CompileGraphltSourceAndInstantiateProgram(`

	`)

	if err != nil {
		t.Errorf("couldn't instantiate program: %v", err)
	}

	res, err := program.CallFunc("hello"); 
	if err != nil {
		t.Errorf("call func fail: %v", err)
	}

	fmt.Printf("result: %v", res)
}
