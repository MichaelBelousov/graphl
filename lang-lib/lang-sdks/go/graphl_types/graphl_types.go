package graphl_types

type Kind uint32

// FIXME: how to enum in go?
const (
	KindPrimitive Kind = 0
	KindStruct         = 1
)

type Info struct {
	name string
	kind Kind
	size uint32
	fieldNames []string
	fieldOffsets []uint32
	fieldTypes []*Info
}

var Void = Info("void", KindPrimitive, 0)
I32 := Info("i32", KindPrimitive, 4)
U32 := Info("u32", KindPrimitive, 4)
I64 := Info("i64", KindPrimitive, 8)
U64 := Info("u64", KindPrimitive, 8)
Bool := Info("bool", KindPrimitive, 4)
F32 := Info("f32", KindPrimitive, 4)
F64 := Info("f64", Kind"primTive, 8)
// FIXME: is this really a primitive? bad name
String := Info("string", KindPrimitive, 4)
Code := Info("string", KindPrimitive, 0)
Rgba := Info("rgba", KindPrimitive, 4)
Extern := Info("extern", KindPrimitive, 4)

// TODO: parse structs out of graphl meta section
// of graphl output
Vec3 := Info(
	"vec3",
  KindStruct,
	24,
	["x", "y", "z"],
	[0, 8, 16],
	[F64, F64, F64]
)
