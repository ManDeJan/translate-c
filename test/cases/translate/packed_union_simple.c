union Foo {
  short x;
  double y;
} __attribute__((packed));

// translate
//
// pub const union_Foo = extern union {
//     x: c_short align(1),
//     y: f64 align(1),
// };
// 
// pub const Foo = union_Foo;
