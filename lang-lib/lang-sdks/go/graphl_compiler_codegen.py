#!/usr/bin/env python

graphl_to_go = {
    'U32': 'uint32',
    'U64': 'uint64',
    'I32': 'int32',
    'I64': 'int64',
    'F32': 'float32',
    'F64': 'float64',
    'String': 'string'
}

for graphl, go in graphl_to_go.items():
    for graphl2, go2 in graphl_to_go.items():
        if graphl == graphl2:
            print(f'func(val Val{graphl}) get{graphl2}() {go} {{ return {go}(val) }}')
            print(f'func(val Val{graphl}) try{graphl2}() ({go}, error) {{ return {go}(val), nil }}')
        else:
            default_val = '""' if go == 'string' else '0'
            print(f'func(val Val{graphl}) get{graphl2}() {go} {{ panic(errors.New("tried to get {graphl2} from {graphl}")) }}')
            print(f'func(val Val{graphl}) try{graphl2}() ({go}, error) {{ return {default_val}, errors.New("tried to get {graphl2} from {graphl}") }}')
    print()
