// The Ball Go runtime value model + base-op helpers.
//
// This module is deliberately dependency-free (Go standard library only), so a
// Ball program compiled to Go can be built and run offline with nothing but
// `import ballrt "github.com/ball-lang/ball/go/runtime"` and a local `replace`.
// It is the Go analog of `ball_lang_shared::runtime` (Rust) / `cpp/shared`
// (C++): the compiler emits `ballrt.*` calls, this module implements them.
module github.com/ball-lang/ball/go/runtime

go 1.23
