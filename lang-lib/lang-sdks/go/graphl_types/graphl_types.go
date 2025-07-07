package graphl_types

type Kind uint32

// FIXME: how to enum in go?
const (
	KindPrimitive Kind = 0
	KindStruct         = 1
)

type Info struct {
	name         string
	kind         Kind
	size         uint32
	fieldNames   []string
	fieldOffsets []uint32
	fieldTypes   []*Info
}

var Void = &Info{"void", KindPrimitive, 0, []string{}, []uint32{}, []*Info{}}
var I32 = &Info{"i32", KindPrimitive, 4, []string{}, []uint32{}, []*Info{}}
var U32 = &Info{"u32", KindPrimitive, 4, []string{}, []uint32{}, []*Info{}}
var I64 = &Info{"i64", KindPrimitive, 8, []string{}, []uint32{}, []*Info{}}
var U64 = &Info{"u64", KindPrimitive, 8, []string{}, []uint32{}, []*Info{}}
var Bool = &Info{"bool", KindPrimitive, 4, []string{}, []uint32{}, []*Info{}}
var F32 = &Info{"f32", KindPrimitive, 4, []string{}, []uint32{}, []*Info{}}
var F64 = &Info{"f64", KindPrimitive, 8, []string{}, []uint32{}, []*Info{}}

// FIXME: is this really a primitive? bad name
var String = &Info{"string", KindPrimitive, 4, []string{}, []uint32{}, []*Info{}}
var Code = &Info{"string", KindPrimitive, 0, []string{}, []uint32{}, []*Info{}}
var Rgba = &Info{"rgba", KindPrimitive, 4, []string{}, []uint32{}, []*Info{}}
var Extern = &Info{"extern", KindPrimitive, 4, []string{}, []uint32{}, []*Info{}}

// TODO: parse structs out of graphl meta section
// of graphl output
var Vec3 = &Info{
	"vec3",
	KindStruct,
	24,
	[]string{"x", "y", "z"},
	[]uint32{0, 8, 16},
	[]*Info{F64, F64, F64},
}
