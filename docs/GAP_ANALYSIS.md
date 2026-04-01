# Ball Language — Full Gap Analysis vs C++ and Dart Specifications

> Generated: 2026-04-01
> Scope: Ball proto schema + std library + Dart implementation + C++ implementation vs official C++17 and Dart 3.x language specs

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Methodology](#methodology)
3. [C++ Gap Analysis](#c-gap-analysis)
   - [Type System](#c-type-system)
   - [Expressions & Operators](#c-expressions--operators)
   - [Control Flow](#c-control-flow)
   - [Functions & Callables](#c-functions--callables)
   - [Classes & OOP](#c-classes--oop)
   - [Templates & Generics](#c-templates--generics)
   - [Memory Management](#c-memory-management)
   - [Preprocessor & Compilation](#c-preprocessor--compilation)
   - [Standard Library](#c-standard-library)
   - [C++17/20 Modern Features](#c1720-modern-features)
   - [Concurrency](#c-concurrency)
4. [Dart Gap Analysis](#dart-gap-analysis)
   - [Type System](#dart-type-system)
   - [Expressions & Operators](#dart-expressions--operators)
   - [Control Flow](#dart-control-flow)
   - [Functions & Callables](#dart-functions--callables)
   - [Classes & OOP](#dart-classes--oop)
   - [Generics](#dart-generics)
   - [Null Safety](#dart-null-safety)
   - [Collections](#dart-collections)
   - [Async/Concurrency](#dart-asyncconcurrency)
   - [Pattern Matching](#dart-pattern-matching)
   - [Dart 3.x Features](#dart-3x-features)
   - [Standard Libraries](#dart-standard-libraries)
5. [Cross-Cutting Gaps](#cross-cutting-gaps)
6. [Summary Tables](#summary-tables)

---

## Executive Summary

Ball currently covers a substantial portion of both C++ and Dart language features through its expression tree, metadata system, and ~164 standard library functions across 5 modules (`std`, `std_collections`, `std_io`, `std_memory`, `dart_std`). However, significant gaps exist in:

- **C++**: Templates (partial), preprocessor (none), RAII/destructors (metadata only), move semantics (none), constexpr (metadata only), concepts (none), coroutines (none), modules (none), concurrency (none), most STL (none)
- **Dart**: Async execution (syntax-only), generics at runtime (erased), pattern matching (partial), isolates (none), streams (none), FFI (metadata only), zones (none), augmentation/macros (none)

**Overall Coverage Estimates:**
- **C++17 core language**: ~55% covered (syntax/semantics)
- **C++17 standard library**: ~15% covered
- **Dart 3.x core language**: ~80% covered
- **Dart core libraries**: ~25% covered

---

## Methodology

Sources analyzed:
1. **Ball schema**: `proto/ball/v1/ball.proto` — all message types, expression variants, type definitions
2. **Ball std library**: `dart/shared/lib/std.dart` — all ~164 base functions across 5 modules
3. **Ball metadata spec**: `docs/METADATA_SPEC.md` — all cosmetic metadata keys
4. **Ball Dart implementation**: compiler (~2000 LOC), encoder (~3000 LOC), engine (~2000 LOC)
5. **Ball C++ implementation**: compiler, encoder, engine
6. **C++ spec reference**: ISO C++17 (N4659), modern-cpp-features list, cppreference.com
7. **Dart spec reference**: Dart 3.x specification draft, dart.dev documentation, Dart 3.0–3.11 changelogs

Legend:
- ✅ = Fully supported (semantic + compilation + interpretation)
- ⚠️ = Partially supported (metadata/syntax only, or incomplete)
- ❌ = Not supported at all
- 🔧 = Broken (implemented but non-functional)

---

## C++ Gap Analysis

### C++ Type System

| C++ Feature | Ball Status | Notes |
|---|---|---|
| **Fundamental types** | | |
| `bool` | ✅ | Literal + type descriptor |
| `char` / `signed char` / `unsigned char` | ⚠️ | Mapped to string; no distinct char type |
| `short` / `unsigned short` | ⚠️ | Mapped to int via memory read/write (i16/u16) |
| `int` / `unsigned int` | ✅ | int64 in proto; i32/u32 via std_memory |
| `long` / `unsigned long` | ✅ | int64/uint64 via proto + memory |
| `long long` / `unsigned long long` | ✅ | int64 native |
| `float` | ⚠️ | double in proto; f32 via std_memory |
| `double` | ✅ | Native double literal |
| `long double` | ❌ | No extended precision support |
| `void` | ✅ | Empty input/output type |
| `nullptr_t` | ✅ | `std_memory.nullptr()` + null literal |
| `wchar_t` / `char8_t` / `char16_t` / `char32_t` | ❌ | No wide/unicode char types |
| `size_t` / `ptrdiff_t` / `intptr_t` | ⚠️ | Mapped to int64; no distinct types |
| **Compound types** | | |
| Pointers (`T*`) | ⚠️ | Via std_memory address arithmetic; no pointer type in proto |
| References (`T&`, `T&&`) | ❌ | No reference semantics; everything is value |
| Arrays (`T[]`, `T[N]`) | ⚠️ | Lists only; no fixed-size arrays |
| `std::string` | ✅ | Native string type + 25 string functions |
| `std::string_view` | ❌ | No non-owning string view |
| `std::vector` | ✅ | List type + 29 list functions |
| `std::array` | ❌ | No fixed-size array type |
| `std::map` / `std::unordered_map` | ✅ | Map type + 13 map functions |
| `std::set` / `std::unordered_set` | ✅ | Set type + 10 set functions |
| `std::tuple` | ❌ | No heterogeneous tuple type |
| `std::pair` | ⚠️ | Via 2-field message creation |
| `std::variant` | ❌ | No type-safe union |
| `std::optional` | ⚠️ | Nullable via metadata; no explicit Optional type |
| `std::any` | ⚠️ | C++ engine uses `std::any` internally; not a Ball type |
| Enums (unscoped) | ✅ | Proto EnumDescriptorProto |
| Enums (scoped, `enum class`) | ✅ | Encoder handles; compiler emits `enum class` |
| Unions | ⚠️ | Metadata `kind: "union"` only; no union memory layout |
| Bitfields | ❌ | No bitfield support |
| **Type qualifiers** | | |
| `const` | ⚠️ | Metadata `is_const`; not enforced at runtime |
| `volatile` | ❌ | No volatile support |
| `mutable` | ⚠️ | Metadata `mutability` field |
| `constexpr` | ⚠️ | Metadata annotation only; no compile-time evaluation |
| `consteval` (C++20) | ❌ | Not supported |
| `constinit` (C++20) | ❌ | Not supported |
| **Type conversions** | | |
| Implicit conversions | ⚠️ | Engine does some auto-coercion (int↔double) |
| `static_cast` | ✅ | Encoder maps to `cpp_std.ptr_cast`; compiler emits |
| `dynamic_cast` | ✅ | Encoder maps to `cpp_std.ptr_cast` |
| `reinterpret_cast` | ✅ | Encoder maps to `cpp_std.ptr_cast` |
| `const_cast` | ✅ | Encoder maps to `cpp_std.ptr_cast` |
| C-style cast | ✅ | Encoder maps to `std.as` |
| **User-defined types** | | |
| `typedef` | ✅ | TypeAlias in proto |
| `using` (type alias) | ✅ | TypeAlias in proto |
| `decltype` | ❌ | No compile-time type deduction |
| `auto` type deduction | ❌ | No auto type in Ball; types explicit or inferred by engine |

### C++ Expressions & Operators

| C++ Feature | Ball Status | Notes |
|---|---|---|
| **Arithmetic** | | |
| `+`, `-`, `*`, `/`, `%` | ✅ | `std.add/subtract/multiply/divide/divide_double/modulo` |
| Unary `-`, `+` | ✅/❌ | `std.negate` for `-`; no unary `+` |
| `++`, `--` (prefix/postfix) | ✅ | `std.pre_increment/post_increment/pre_decrement/post_decrement` |
| **Comparison** | | |
| `==`, `!=`, `<`, `>`, `<=`, `>=` | ✅ | All mapped to std functions |
| Three-way `<=>` (C++20) | ❌ | Spaceship operator not supported |
| **Logical** | | |
| `&&`, `\|\|`, `!` | ✅ | `std.and/or/not` with short-circuit |
| **Bitwise** | | |
| `&`, `\|`, `^`, `~`, `<<`, `>>` | ✅ | All mapped to std functions |
| **Assignment** | | |
| `=` | ✅ | `std.assign` |
| `+=`, `-=`, `*=`, `/=`, `%=` | ✅ | `std.assign` with op field |
| `&=`, `\|=`, `^=`, `<<=`, `>>=` | ✅ | `std.assign` with op field |
| **Member access** | | |
| `.` (member access) | ✅ | FieldAccess expression |
| `->` (pointer member) | ⚠️ | Encoder maps to `cpp_std.arrow`; partial |
| `.*`, `->*` (pointer-to-member) | ❌ | No pointer-to-member support |
| **Subscript** | | |
| `[]` (array/index) | ✅ | `std.index` |
| **Function call** | | |
| `()` (function call) | ✅ | FunctionCall expression |
| **Ternary** | | |
| `? :` (conditional) | ✅ | Mapped to `std.if` |
| **Comma** | | |
| `,` (comma operator) | ❌ | No comma operator; use Block |
| **Sizeof / Alignof** | | |
| `sizeof` | ✅ | Encoder maps to `cpp_std.cpp_sizeof` |
| `alignof` | ✅ | Encoder maps to `cpp_std.cpp_alignof` |
| `sizeof...` (parameter pack) | ❌ | No variadic template support |
| **Others** | | |
| `typeid` | ❌ | No RTTI operator |
| `noexcept` (operator) | ❌ | Not supported |
| `throw` (expression) | ✅ | `std.throw` |
| `new` / `delete` | ✅ | Encoder maps to `cpp_std.cpp_new/cpp_delete` |
| Placement `new` | ❌ | Not supported |
| `co_await` / `co_yield` / `co_return` (C++20) | ❌ | Not supported |

### C++ Control Flow

| C++ Feature | Ball Status | Notes |
|---|---|---|
| `if` / `else` | ✅ | `std.if` with lazy evaluation |
| `if` with initializer (C++17) | ⚠️ | Can encode via Block in condition; not native |
| `if constexpr` (C++17) | ❌ | No compile-time conditional |
| `switch` / `case` / `default` | ✅ | `std.switch` |
| `switch` with initializer (C++17) | ⚠️ | Same as if-with-init |
| `for` (C-style) | ✅ | `std.for` |
| Range-based `for` | ✅ | `std.for_in` |
| `while` | ✅ | `std.while` |
| `do-while` | ✅ | `std.do_while` |
| `break` | ✅ | `std.break` with optional label |
| `continue` | ✅ | `std.continue` with optional label |
| `return` | ✅ | `std.return` |
| `goto` | ❌ | No goto support (by design) |
| Labels (for goto) | ⚠️ | Labels exist for break/continue only |
| `try` / `catch` / `throw` | ✅ | `std.try` with catch clauses |
| `noexcept` specification | ⚠️ | Metadata annotation only |
| Exception specifications | ❌ | Deprecated in C++; not supported |

### C++ Functions & Callables

| C++ Feature | Ball Status | Notes |
|---|---|---|
| Free functions | ✅ | FunctionDefinition |
| Function overloading | ❌ | Ball functions are name-unique per module |
| Default arguments | ⚠️ | Via metadata `params[].default` |
| Variadic functions (`...`) | ❌ | No variadic arguments |
| Variadic templates | ❌ | No parameter packs |
| Lambda expressions | ✅ | Lambda expression type (FunctionDefinition with empty name) |
| Generic lambdas (C++14) | ❌ | No auto-typed lambda params |
| `constexpr` lambdas (C++17) | ❌ | No compile-time lambdas |
| Lambda `*this` capture (C++17) | ❌ | No explicit capture specification |
| `std::function` | ⚠️ | Lambda type maps to function type |
| Function pointers | ❌ | No function pointer type |
| Member function pointers | ❌ | No member pointer type |
| Inline functions | ⚠️ | Metadata annotation `inline` |
| `constexpr` functions | ⚠️ | Metadata annotation only |
| `consteval` functions (C++20) | ❌ | Not supported |
| Trailing return types | ❌ | Not applicable (type always in output_type) |
| Structured bindings (C++17) | ❌ | No destructuring declaration |
| `[[nodiscard]]` attribute | ⚠️ | Can be stored in metadata annotations |
| `[[maybe_unused]]` attribute | ⚠️ | Can be stored in metadata annotations |
| `[[fallthrough]]` attribute | ⚠️ | Can be stored in metadata annotations |
| `[[deprecated]]` attribute | ⚠️ | Can be stored in metadata annotations |

### C++ Classes & OOP

| C++ Feature | Ball Status | Notes |
|---|---|---|
| Class definition | ✅ | TypeDefinition with kind: "class" |
| Struct definition | ✅ | TypeDefinition with kind: "struct" |
| Access specifiers (`public`/`private`/`protected`) | ⚠️ | Metadata `visibility` only; not enforced |
| Constructors (default, parameterized, copy, move) | ⚠️ | Default + parameterized via metadata; no copy/move semantics |
| Destructor | ⚠️ | Encoder captures `~ClassName`; metadata `annotations: [destructor]` |
| Copy constructor | ❌ | No copy semantics |
| Move constructor | ❌ | No move semantics |
| Copy assignment operator | ❌ | No copy assignment |
| Move assignment operator | ❌ | No move assignment |
| RAII | ❌ | No deterministic destruction |
| Rule of 0/3/5 | ❌ | No special member function generation |
| Single inheritance | ✅ | Metadata `superclass` |
| Multiple inheritance | ❌ | Ball only supports single superclass (like Dart/Java) |
| Virtual functions | ⚠️ | Metadata annotation `virtual`; no vtable simulation |
| Pure virtual / abstract | ⚠️ | Metadata `is_abstract` |
| Virtual inheritance | ❌ | No virtual inheritance support |
| Override | ⚠️ | Metadata `is_override` |
| `final` (class/method) | ✅ | Metadata `is_final` |
| Static members | ✅ | Metadata `is_static` |
| `friend` | ❌ | No friend access |
| Nested classes | ❌ | No nested type definitions |
| Operator overloading | ⚠️ | Metadata `kind: "operator"` + `is_operator`; limited compilation |
| Conversion operators | ❌ | No implicit/explicit conversion operators |
| `explicit` keyword | ⚠️ | Metadata annotation `explicit` |
| Aggregate initialization | ⚠️ | MessageCreation with fields |
| Designated initializers (C++20) | ❌ | Not supported |

### C++ Templates & Generics

| C++ Feature | Ball Status | Notes |
|---|---|---|
| Function templates | ⚠️ | Encoder parses `FunctionTemplateDecl`; stores type_params in metadata |
| Class templates | ⚠️ | Encoder parses `ClassTemplateDecl`; stores type_params in metadata |
| Template specialization (full) | ❌ | No specialization support |
| Template specialization (partial) | ❌ | No partial specialization |
| Template parameter packs | ❌ | No variadic templates |
| Fold expressions (C++17) | ❌ | No fold support |
| Non-type template parameters | ❌ | Only type parameters stored |
| `auto` template parameters (C++17) | ❌ | Not supported |
| CTAD (C++17) | ❌ | No class template argument deduction |
| SFINAE | ❌ | No substitution failure handling |
| `template` keyword disambiguation | ❌ | Not applicable |
| `typename` keyword disambiguation | ❌ | Not applicable |
| `if constexpr` (C++17) | ❌ | No compile-time branching |
| Concepts (C++20) | ❌ | No concept constraints |
| `requires` clauses (C++20) | ❌ | No requires expressions |
| Variable templates (C++14) | ❌ | No variable templates |
| Alias templates | ⚠️ | TypeAlias with type_params |
| `extern template` | ❌ | No template instantiation control |

### C++ Memory Management

| C++ Feature | Ball Status | Notes |
|---|---|---|
| Stack allocation | ✅ | `std_memory.stack_alloc/push_frame/pop_frame` |
| Heap allocation (`new`/`delete`) | ✅ | `std_memory.memory_alloc/free` + `cpp_std.cpp_new/cpp_delete` |
| `malloc`/`free` | ✅ | `std_memory.memory_alloc/free` |
| `realloc` | ✅ | `std_memory.memory_realloc` |
| Typed read/write (8/16/32/64-bit, float/double) | ✅ | 20 `memory_read_*/memory_write_*` functions |
| `memcpy`/`memmove` | ✅ | `std_memory.memory_copy` |
| `memset` | ✅ | `std_memory.memory_set` |
| `memcmp` | ✅ | `std_memory.memory_compare` |
| Pointer arithmetic | ✅ | `std_memory.ptr_add/ptr_sub/ptr_diff` |
| `sizeof` / `alignof` | ✅ | `std_memory.memory_sizeof` + `cpp_std.cpp_sizeof/cpp_alignof` |
| Smart pointers (`unique_ptr`, `shared_ptr`, `weak_ptr`) | ❌ | No smart pointer types |
| `std::make_unique` / `std::make_shared` | ❌ | No smart pointer factories |
| RAII-based deallocation | ❌ | No deterministic destruction |
| Custom allocators | ❌ | No allocator abstraction |
| Placement new | ❌ | No placement new support |
| Memory order / atomics | ❌ | No atomic memory operations |
| `std::launder` (C++17) | ❌ | No laundering support |

### C++ Preprocessor & Compilation

| C++ Feature | Ball Status | Notes |
|---|---|---|
| `#include` | ⚠️ | Module metadata `cpp_includes`; not functional |
| `#define` / macros | ❌ | No preprocessor; Ball programs are structured data |
| `#ifdef` / `#ifndef` / `#if` | ❌ | No conditional compilation |
| `#pragma` | ❌ | No pragma support |
| `__has_include` (C++17) | ❌ | No include checking |
| `#line` | ❌ | Not applicable |
| Token pasting (`##`) | ❌ | Not applicable |
| Stringification (`#`) | ❌ | Not applicable |
| Translation units | ⚠️ | Modules loosely correspond |
| Linkage (`extern`, `static`) | ⚠️ | Metadata only |
| `inline` variables (C++17) | ⚠️ | Metadata annotation |
| Namespaces | ⚠️ | Encoder extracts namespace prefixes; not a first-class concept |
| Nested namespaces (C++17) | ⚠️ | Flattened into name mangling |
| Anonymous namespaces | ❌ | Not supported |
| `using namespace` | ⚠️ | Metadata only |
| Modules (C++20) | ❌ | Ball has its own module system (not C++ modules) |

### C++ Standard Library

| C++ STL Feature | Ball Status | Notes |
|---|---|---|
| **Containers** | | |
| `vector` | ✅ | Ball lists |
| `array` | ❌ | No fixed-size arrays |
| `deque` | ❌ | No deque type |
| `list` / `forward_list` | ❌ | No linked list type |
| `map` / `multimap` | ⚠️ | Ball maps (no multimap) |
| `unordered_map` / `unordered_multimap` | ⚠️ | Ball maps (no multi) |
| `set` / `multiset` | ⚠️ | Ball sets (no multiset) |
| `unordered_set` / `unordered_multiset` | ⚠️ | Ball sets (no multi) |
| `stack` | ❌ | No stack adapter |
| `queue` / `priority_queue` | ❌ | No queue adapters |
| **Iterators** | ❌ | No iterator concept; for_in uses list iteration |
| **Algorithms** | | |
| `sort` | ✅ | `list_sort` / `list_sort_by` |
| `find` / `find_if` | ✅ | `list_find` / `list_filter` |
| `count` / `count_if` | ❌ | No count functions |
| `transform` | ✅ | `list_map` |
| `accumulate`/`reduce` | ✅ | `list_reduce` |
| `copy` / `move` | ❌ | No copy/move algorithms |
| `remove` / `remove_if` | ⚠️ | `list_filter` (creates new list) |
| `reverse` | ✅ | `list_reverse` |
| `unique` | ❌ | No unique algorithm |
| `binary_search` | ❌ | No binary search |
| `min` / `max` / `clamp` | ✅ | `math_min` / `math_max` / `math_clamp` |
| `any_of` / `all_of` / `none_of` | ✅ | `list_any` / `list_all` / `list_none` |
| `for_each` | ⚠️ | Via `list_map` (but creates result) |
| Parallel algorithms (C++17) | ❌ | No execution policies |
| **Strings** | | |
| `std::string` operations | ✅ | 25+ string functions |
| `std::string_view` (C++17) | ❌ | No string view |
| `std::to_chars` / `std::from_chars` (C++17) | ✅ | `int_to_string` / `string_to_int` |
| **I/O** | | |
| `iostream` (cout/cin/cerr) | ✅ | `print` / `read_line` / `print_error` |
| `fstream` (file I/O) | ❌ | No file I/O |
| `sstream` (string streams) | ❌ | No string streams |
| **Utilities** | | |
| `std::optional` (C++17) | ❌ | No optional type |
| `std::variant` (C++17) | ❌ | No variant type |
| `std::any` (C++17) | ❌ | No any type (used internally only) |
| `std::function` | ⚠️ | Lambda type loosely corresponds |
| `std::bind` | ❌ | No bind |
| `std::chrono` | ⚠️ | Only `timestamp_ms` / `sleep_ms` |
| `std::filesystem` (C++17) | ❌ | No filesystem access |
| `std::regex` | ✅ | 5 regex functions |
| `std::thread` / `std::mutex` | ❌ | No threading |
| `std::atomic` | ❌ | No atomics |
| `std::future` / `std::promise` | ❌ | No futures |
| **Math** | | |
| `<cmath>` functions | ✅ | 30+ math functions (trig, log, pow, etc.) |
| `<numeric>` | ⚠️ | `gcd` / `lcm` only |
| `<random>` | ⚠️ | `random_int` / `random_double` only |

### C++17/20 Modern Features

| Feature | Ball Status | Notes |
|---|---|---|
| **C++17** | | |
| Structured bindings | ❌ | No destructuring |
| `if constexpr` | ❌ | No compile-time branching |
| Fold expressions | ❌ | No fold over parameter packs |
| Inline variables | ⚠️ | Metadata annotation |
| Nested namespaces | ⚠️ | Encoder flattens to name prefix |
| Class template argument deduction | ❌ | No CTAD |
| `[[fallthrough]]` / `[[nodiscard]]` / `[[maybe_unused]]` | ⚠️ | Metadata annotations |
| `std::optional` / `variant` / `any` | ❌ | Not modeled |
| `std::string_view` | ❌ | Not modeled |
| `std::filesystem` | ❌ | Not modeled |
| `std::byte` | ❌ | Using raw bytes via memory module |
| Parallel algorithms | ❌ | Not supported |
| Selection statements with initializer | ⚠️ | Block-in-condition workaround |
| UTF-8 character literals | ❌ | No char type |
| **C++20** | | |
| Concepts | ❌ | Not supported |
| Ranges | ❌ | Not supported |
| Coroutines (`co_await`/`co_yield`/`co_return`) | ❌ | Not supported |
| Modules (`import`/`export`/`module`) | ❌ | Ball has own module system |
| Three-way comparison `<=>` | ❌ | Not supported |
| `consteval` / `constinit` | ❌ | Not supported |
| Designated initializers | ❌ | Not supported |
| `[[likely]]` / `[[unlikely]]` | ❌ | Not supported |
| `std::format` | ❌ | Not supported |
| `std::span` | ❌ | Not supported |

### C++ Concurrency

| Feature | Ball Status | Notes |
|---|---|---|
| `std::thread` | ❌ | No threading |
| `std::mutex` / `std::lock_guard` / `std::unique_lock` | ❌ | No mutexes |
| `std::condition_variable` | ❌ | No condition variables |
| `std::atomic` | ❌ | No atomics |
| `std::future` / `std::promise` / `std::async` | ❌ | No futures |
| `std::shared_mutex` (C++17) | ❌ | No shared mutexes |
| `std::jthread` (C++20) | ❌ | No jthread |
| `std::latch` / `std::barrier` (C++20) | ❌ | No latches/barriers |
| `std::semaphore` (C++20) | ❌ | No semaphores |
| Memory ordering | ❌ | No memory model |
| Thread-local storage (`thread_local`) | ❌ | No TLS |

---

## Dart Gap Analysis

### Dart Type System

| Dart Feature | Ball Status | Notes |
|---|---|---|
| **Primitive types** | | |
| `int` | ✅ | int64 in proto |
| `double` | ✅ | Native double literal |
| `num` | ⚠️ | Engine resolves at runtime; no distinct proto type |
| `String` | ✅ | Native string type |
| `bool` | ✅ | Native bool type |
| `Null` | ✅ | Null checks via `is` operator |
| `void` | ✅ | Empty input/output type |
| `dynamic` | ⚠️ | Engine uses dynamic dispatch; no explicit type |
| `Object` / `Object?` | ⚠️ | Mapped to `std::any` in C++; no explicit proto type |
| `Never` | ❌ | No bottom type |
| `Function` | ⚠️ | Lambda type; no explicit Function type descriptor |
| `Type` | ⚠️ | `dart_std.type_literal` for type-as-value |
| `Symbol` | ✅ | `dart_std.symbol` |
| **Collection types** | | |
| `List<T>` | ✅ | ListLiteral + 29 list functions |
| `Set<T>` | ✅ | `dart_std.set_create` + 10 set functions |
| `Map<K,V>` | ✅ | `dart_std.map_create` + 13 map functions |
| `Iterable<T>` | ⚠️ | for_in works on lists; no distinct Iterable type |
| `Queue` | ❌ | No queue type |
| `LinkedList` | ❌ | No linked list |
| `SplayTreeMap` / `SplayTreeSet` | ❌ | No tree-based collections |
| **Special types** | | |
| `Future<T>` | ⚠️ | `std.await` exists but is no-op; type mapped in metadata |
| `Stream<T>` | ❌ | No stream type |
| `Completer<T>` | ❌ | No completer type |
| `Record` | ✅ | `dart_std.record` |
| `Enum` | ✅ | TypeDefinition with kind: "enum" |
| `BigInt` | ❌ | No arbitrary-precision integers |
| `DateTime` | ❌ | Only `timestamp_ms()` |
| `Duration` | ❌ | Only `sleep_ms()` |
| `Uri` | ❌ | No URI type |
| `RegExp` | ✅ | 5 regex functions |
| `Pattern` | ⚠️ | Via regex functions |
| `StackTrace` | ⚠️ | Catch clause can bind stack_trace variable |
| **Type features** | | |
| Type inference | ⚠️ | Engine infers dynamically; compiler emits explicit types |
| Type promotion (flow analysis) | ❌ | No compile-time flow analysis in Ball |
| Covariant generics | ⚠️ | Stored in metadata; not enforced |
| Contravariant generics | ⚠️ | Stored in metadata; not enforced |
| Function types (`void Function(int)`) | ⚠️ | Lambda type; no first-class function type descriptor |
| Typedef | ✅ | TypeAlias |

### Dart Expressions & Operators

| Dart Feature | Ball Status | Notes |
|---|---|---|
| **Arithmetic** | | |
| `+`, `-`, `*`, `%` | ✅ | Mapped to std functions |
| `/` (double division) | ✅ | `std.divide_double` |
| `~/` (integer division) | ✅ | `std.divide` |
| Unary `-` | ✅ | `std.negate` |
| `++`, `--` (prefix/postfix) | ✅ | All four variants |
| **Comparison** | ✅ | All 6 operators |
| **Logical** | ✅ | `&&`, `\|\|`, `!` with short-circuit |
| **Bitwise** | ✅ | All 7 operators including `>>>` |
| **Assignment** | | |
| `=` | ✅ | `std.assign` |
| `+=`, `-=`, `*=`, `/=`, `~/=`, `%=` | ✅ | `std.assign` with op |
| `&=`, `\|=`, `^=`, `<<=`, `>>=`, `>>>=` | ✅ | `std.assign` with op |
| `??=` | ✅ | `std.assign` with op `??=` |
| **Null-aware** | | |
| `??` (null coalescing) | ✅ | `std.null_coalesce` |
| `!` (null assertion) | ✅ | `std.null_check` |
| `?.` (null-aware access) | ✅ | `dart_std.null_aware_access` |
| `?.()` (null-aware method call) | ✅ | `dart_std.null_aware_call` |
| `?..` (null-aware cascade) | ⚠️ | Via cascade with null-aware access; no distinct function |
| `?[]` (null-aware index) | ✅ | `dart_std.null_aware_index` |
| **Type test** | | |
| `is` | ✅ | `std.is` |
| `is!` | ✅ | `std.is_not` |
| `as` (typecast) | ✅ | `std.as` |
| **Cascade** | | |
| `..` (cascade) | ✅ | `dart_std.cascade` |
| `?..` (null-aware cascade) | ⚠️ | Partial via cascade |
| **Spread** | | |
| `...` (spread) | ✅ | `dart_std.spread` |
| `...?` (null-aware spread) | ✅ | `dart_std.null_spread` |
| **Other** | | |
| `[]` (index) | ✅ | `std.index` |
| `[]=` (index assignment) | ✅ | `std.assign` with index target |
| String interpolation (`$x`, `${expr}`) | ✅ | `string_interpolation` function |
| Conditional `? :` (ternary) | ✅ | `std.if` |
| `throw` (as expression) | ✅ | `std.throw` |
| Parentheses | ✅ | `std.paren` / pass-through |

### Dart Control Flow

| Dart Feature | Ball Status | Notes |
|---|---|---|
| `if` / `else` | ✅ | `std.if` with lazy evaluation |
| `if-case` (Dart 3) | ✅ | `std.if` with `case_pattern` metadata |
| `for` (C-style) | ✅ | `std.for` |
| `for-in` | ✅ | `std.for_in` |
| `await for` | ⚠️ | Parsed and stored; no async execution |
| `while` | ✅ | `std.while` |
| `do-while` | ✅ | `std.do_while` |
| `switch` (statement) | ✅ | `std.switch` |
| `switch` (expression, Dart 3) | ✅ | `dart_std.switch_expr` |
| `break` (with optional label) | ✅ | `std.break` |
| `continue` (with optional label) | ✅ | `std.continue` |
| `return` | ✅ | `std.return` |
| `try` / `catch` / `on` / `finally` | ✅ | `std.try` with typed catch clauses |
| `throw` | ✅ | `std.throw` |
| `rethrow` | ✅ | `std.rethrow` |
| `assert` | ✅ | `std.assert` |
| Labeled statements | ✅ | `dart_std.labeled` |
| Collection `if` (`[if (cond) x]`) | ✅ | `dart_std.collection_if` |
| Collection `for` (`[for (x in y) z]`) | ✅ | `dart_std.collection_for` |

### Dart Functions & Callables

| Dart Feature | Ball Status | Notes |
|---|---|---|
| Top-level functions | ✅ | FunctionDefinition in module |
| Named functions | ✅ | Name field in FunctionDefinition |
| Anonymous functions (lambdas) | ✅ | Lambda expression |
| Arrow functions (`=> expr`) | ✅ | Metadata `expression_body: true` |
| Positional parameters | ✅ | Via metadata `params[].kind: "positional"` |
| Named parameters | ✅ | Via metadata `params[].kind: "named"` |
| Optional positional parameters | ✅ | Via metadata `params[].kind: "optional"` |
| Default parameter values | ✅ | Via metadata `params[].default` |
| Local functions | ✅ | Encoded as LetBinding with lambda value |
| Closures (variable capture) | ✅ | Lexical scope capture in engine |
| Tear-offs (function references) | ❌ | No tear-off syntax |
| Function types as values | ⚠️ | Lambdas stored in variables; no first-class Function type |
| `typedef` (function type alias) | ✅ | TypeAlias |
| Getters | ✅ | Metadata `is_getter` + `kind: "getter"` |
| Setters | ✅ | Metadata `is_setter` + `kind: "setter"` |
| Operator methods | ✅ | Metadata `is_operator` + `kind: "operator"` |
| `external` functions | ✅ | Metadata `is_external` |
| `async` functions | ⚠️ | Metadata `is_async`; emitted correctly; not executed |
| `async*` generators | ⚠️ | Metadata `is_async_star`; emitted; not executed |
| `sync*` generators | ⚠️ | Metadata `is_sync_star`; emitted; not executed |
| `yield` | ⚠️ | `std.yield`; emitted; no-op in engine |
| `yield*` | ⚠️ | `dart_std.yield_each`; emitted; no-op in engine |
| `await` | ⚠️ | `std.await`; emitted; no-op in engine |
| Static methods | ✅ | Metadata `is_static` |

### Dart Classes & OOP

| Dart Feature | Ball Status | Notes |
|---|---|---|
| Class declaration | ✅ | TypeDefinition with kind: "class" |
| `abstract` class | ✅ | Metadata `is_abstract` |
| `sealed` class (Dart 3) | ✅ | Metadata `is_sealed` |
| `base` class (Dart 3) | ✅ | Metadata `is_base` |
| `interface` class (Dart 3) | ✅ | Metadata `is_interface` |
| `final` class (Dart 3) | ✅ | Metadata `is_final` |
| `mixin class` (Dart 3) | ✅ | Metadata `is_mixin_class` |
| `mixin` declaration | ✅ | TypeDefinition with kind: "mixin" |
| `mixin` with `on` constraint | ✅ | Metadata `on` |
| `extends` (single inheritance) | ✅ | Metadata `superclass` |
| `implements` (interfaces) | ✅ | Metadata `interfaces[]` |
| `with` (mixins) | ✅ | Metadata `mixins[]` |
| Constructors (default) | ✅ | FunctionDefinition with kind: "constructor" |
| Named constructors | ✅ | Metadata `constructor_name` |
| Factory constructors | ✅ | Metadata `is_factory` |
| `const` constructors | ✅ | Metadata `is_const` |
| Redirecting constructors | ✅ | Metadata `redirects_to` |
| Initializer lists | ✅ | Metadata `initializers` (as source string) |
| Super constructor calls | ⚠️ | Via initializer list string |
| Instance fields | ✅ | Via TypeDefinition descriptor + metadata `fields[]` |
| `final` fields | ✅ | Metadata `fields[].is_final` |
| `const` fields | ✅ | Metadata `fields[].is_const` |
| `late` fields | ✅ | Metadata `fields[].is_late` |
| Static fields | ✅ | Encoded as static_field kind functions |
| Abstract fields | ✅ | Metadata `fields[].is_abstract` |
| Instance methods | ✅ | FunctionDefinition with method kind |
| Static methods | ✅ | Metadata `is_static` |
| Abstract methods | ✅ | Metadata `is_abstract` |
| Getters / Setters | ✅ | Metadata `is_getter`/`is_setter` |
| Operator overloading | ✅ | Metadata `is_operator` |
| `@override` annotation | ✅ | Metadata `is_override` |
| `noSuchMethod` | ❌ | No dynamic dispatch interception |
| `toString()` / `hashCode` / `==` | ⚠️ | Can be defined as methods; not auto-generated |
| Extension methods | ✅ | TypeDefinition with kind: "extension" + `on` metadata |
| Extension types (Dart 3.3) | ✅ | TypeDefinition with kind: "extension_type" + representation |
| Enums (enhanced, Dart 2.17) | ✅ | TypeDefinition with kind: "enum", fields, values, constructors |
| **Runtime behavior** | | |
| Instantiation (constructor call) | ⚠️ | Engine creates Map; no real class instantiation |
| Inheritance chain resolution | ❌ | Engine doesn't simulate inheritance |
| Dynamic dispatch (virtual methods) | ❌ | Engine calls function by name; no vtable |
| `super` keyword | ⚠️ | Via initializer list string; no runtime super access |

### Dart Generics

| Dart Feature | Ball Status | Notes |
|---|---|---|
| Generic classes (`class Box<T>`) | ✅ | TypeParameter in TypeDefinition |
| Generic methods (`T first<T>(List<T> list)`) | ✅ | `type_params` in function metadata |
| Generic functions | ✅ | `type_params` in function metadata |
| Generic extensions | ✅ | TypeParameter in extension |
| Generic mixins | ✅ | TypeParameter in mixin |
| Type bounds (`T extends Comparable`) | ✅ | TypeParameter metadata `extends` |
| Covariant keyword | ⚠️ | Metadata `variance: "covariant"` |
| Reified generics (runtime type args) | ❌ | Type-erased at runtime in engine |
| Generic type aliases | ✅ | TypeAlias with type_params |
| F-bounded polymorphism | ⚠️ | Syntax preserved; no semantic enforcement |

### Dart Null Safety

| Dart Feature | Ball Status | Notes |
|---|---|---|
| Non-nullable by default | ⚠️ | Ball values can be null regardless; metadata hints only |
| Nullable types (`T?`) | ⚠️ | Type annotations in metadata; not enforced |
| `!` (null assertion operator) | ✅ | `std.null_check` |
| `??` (null coalescing) | ✅ | `std.null_coalesce` |
| `??=` (null-aware assignment) | ✅ | `std.assign` with op `??=` |
| `?.` (null-aware access) | ✅ | `dart_std.null_aware_access` |
| `?..` (null-aware cascade) | ⚠️ | Partial |
| `?[]` (null-aware index) | ✅ | `dart_std.null_aware_index` |
| `late` variables | ⚠️ | Metadata `is_late`; no lazy init enforcement |
| `required` keyword | ⚠️ | Via params metadata |
| Flow analysis (type promotion) | ❌ | No compile-time flow analysis |
| Sound null safety enforcement | ❌ | Engine doesn't enforce null safety |

### Dart Collections

| Dart Feature | Ball Status | Notes |
|---|---|---|
| List literals (`[]`) | ✅ | ListLiteral |
| Map literals (`{}`) | ✅ | `dart_std.map_create` |
| Set literals (`{}`) | ✅ | `dart_std.set_create` |
| Record literals (`()`) | ✅ | `dart_std.record` |
| Collection `if` | ✅ | `dart_std.collection_if` |
| Collection `for` | ✅ | `dart_std.collection_for` |
| Spread operator (`...`) | ✅ | `dart_std.spread` |
| Null-aware spread (`...?`) | ✅ | `dart_std.null_spread` |
| `List.generate` | ❌ | No list generator function |
| `List.filled` | ❌ | No filled list constructor |
| `List.from` / `List.of` | ❌ | No list conversion constructors |
| `List.unmodifiable` | ❌ | No unmodifiable collections |
| `Map.fromEntries` | ✅ | `std_collections.map_from_entries` |
| `Iterable` methods (`.where`, `.map`, `.fold`, etc.) | ✅ | Via `list_filter`, `list_map`, `list_reduce` |
| `Iterable.expand` (flatMap) | ✅ | `list_flat_map` |
| `Iterable.zip` | ✅ | `list_zip` |
| `Iterable.take` / `Iterable.skip` | ✅ | `list_take` / `list_drop` |
| `Iterable.toList()` / `.toSet()` | ⚠️ | Via `set_to_list`; no `toSet` |
| Typed data (`Uint8List`, `Int32List`, etc.) | ❌ | Only via std_memory |
| `ByteData` / `ByteBuffer` | ⚠️ | std_memory simulates ByteData |

### Dart Async/Concurrency

| Dart Feature | Ball Status | Notes |
|---|---|---|
| `Future<T>` | ⚠️ | Syntax emitted; no execution model |
| `async` functions | ⚠️ | Metadata `is_async`; emitted correctly |
| `await` expression | ⚠️ | `std.await`; emitted; no-op in engine |
| `Future.then()` / `.catchError()` | ❌ | No Future methods |
| `Future.wait()` / `Future.any()` | ❌ | No Future combinators |
| `Completer<T>` | ❌ | No completer |
| `Stream<T>` | ❌ | No stream type |
| `StreamController` | ❌ | No stream controllers |
| `await for` (stream iteration) | ⚠️ | Parsed; no-op in engine |
| `async*` generators | ⚠️ | Metadata `is_async_star`; emitted; no execution |
| `sync*` generators | ⚠️ | Metadata `is_sync_star`; emitted; no execution |
| `yield` | ⚠️ | `std.yield`; emitted; no generator state |
| `yield*` | ⚠️ | `dart_std.yield_each`; emitted; no generator state |
| Isolates (`Isolate.spawn`) | ❌ | No isolate support |
| `compute()` function | ❌ | No compute |
| `Zone` / `runZoned()` | ❌ | No zone support |
| `Timer` (periodic/one-shot) | ❌ | No timer |
| Microtask queue | ❌ | No event loop model |

### Dart Pattern Matching

| Dart Feature | Ball Status | Notes |
|---|---|---|
| `switch` expression (Dart 3) | ✅ | `dart_std.switch_expr` |
| `if-case` (Dart 3) | ✅ | `std.if` with `case_pattern` metadata |
| Constant patterns | ⚠️ | value in switch case |
| Variable patterns | ⚠️ | Stored as pattern string in metadata |
| Wildcard patterns (`_`) | ⚠️ | Stored in pattern string |
| Type test patterns (`int x`) | ⚠️ | Stored in pattern string |
| Cast patterns (`x as int`) | ⚠️ | Stored in pattern string |
| List patterns (`[a, b, ...]`) | ⚠️ | Stored in pattern string; no semantic matching |
| Map patterns (`{'key': value}`) | ⚠️ | Stored in pattern string |
| Record patterns (`(a, b: c)`) | ⚠️ | Stored in pattern string |
| Object patterns (`Foo(x: y)`) | ⚠️ | Stored in pattern string |
| Logical patterns (`&&`, `\|\|`) | ⚠️ | Stored in pattern string |
| Relational patterns (`< 5`) | ⚠️ | Stored in pattern string |
| Guard clauses (`when expr`) | ⚠️ | Stored in case metadata |
| **Engine execution** | | |
| Pattern matching in switch_expr | ⚠️ | Eager evaluation; basic value matching only |
| Destructuring in patterns | ❌ | Engine doesn't destructure |
| Exhaustiveness checking | ❌ | No compile-time exhaustiveness |

### Dart 3.x Features

| Dart 3.x Feature | Ball Status | Notes |
|---|---|---|
| Records | ✅ | `dart_std.record` |
| Patterns | ⚠️ | Stored as strings; not semantically processed |
| Sealed classes | ✅ | Metadata `is_sealed` |
| Class modifiers (`base`/`interface`/`final`/`mixin`) | ✅ | All in metadata |
| Switch expressions | ✅ | `dart_std.switch_expr` |
| `if-case` | ✅ | `std.if` with pattern metadata |
| Extension types (Dart 3.3) | ✅ | TypeDefinition with kind: "extension_type" |
| Dot shorthands (Dart 3.10) | ❌ | Not implemented |
| Wildcard variables `_` (Dart 3.1) | ⚠️ | Parsed by encoder; stored in metadata |
| Class modifier combinations | ✅ | All combinations supported via metadata |
| Augmentation (experimental) | ❌ | Not implemented |
| Macros (experimental) | ❌ | Not implemented |
| Static metaprogramming | ❌ | Not implemented |
| Inline classes | ❌ | Dart removed this proposal; extension types replace it |

### Dart Standard Libraries

| Dart Library | Ball Status | Notes |
|---|---|---|
| `dart:core` | | |
| - `int`, `double`, `String`, `bool`, `List`, `Map`, `Set` | ✅ | Core types + operations |
| - `Object`, `Comparable`, `Pattern` | ⚠️ | Not modeled as Ball types |
| - `Error` / `Exception` hierarchy | ⚠️ | `std.throw` works; no type hierarchy |
| - `Iterable` | ⚠️ | List methods only; no Iterable abstraction |
| - `RegExp` | ✅ | 5 regex functions |
| - `DateTime` / `Duration` | ❌ | Only `timestamp_ms` / `sleep_ms` |
| - `Uri` | ❌ | No URI support |
| - `BigInt` | ❌ | No big integer support |
| - `StringBuffer` | ❌ | No string buffer |
| - `Runes` / `RuneIterator` | ❌ | No rune support |
| `dart:math` | ✅ | 30+ math functions cover most of dart:math |
| `dart:collection` | ⚠️ | Basic list/map/set only; no Queue, HashMap variants |
| `dart:convert` | ❌ | No JSON/UTF-8 encode/decode |
| `dart:async` | ❌ | No Future/Stream/Completer/Timer |
| `dart:io` | ⚠️ | `print`, `read_line`, `exit` only; no file/socket/HTTP |
| `dart:typed_data` | ⚠️ | Via std_memory; no Uint8List/Float64List types |
| `dart:isolate` | ❌ | No isolate support |
| `dart:ffi` | ❌ | No FFI execution (metadata preserved) |
| `dart:js_interop` | ❌ | No JS interop |
| `dart:mirrors` | ❌ | No reflection |
| `dart:developer` | ❌ | No developer tools |

---

## Cross-Cutting Gaps

These gaps affect both C++ and Dart targets:

| Gap Category | Description | Impact |
|---|---|---|
| **Multiple parameters** | Ball enforces single input/output per function (by design). Multi-param functions use message wrapping. | Verbose encoding; round-trip adds wrapper types |
| **Function overloading** | Ball functions are name-unique per module. No overloading by parameter type. | C++ overloads must be name-mangled; Dart extension methods must be unique |
| **Generics at runtime** | Type parameters stored in metadata but erased at runtime in engine. | No generic type checking, no reified generics |
| **Inheritance runtime** | Engine creates Map-based "objects" with no inheritance chain. | No `super` calls, no virtual dispatch, no method resolution order |
| **Async execution** | Both engines treat async/await/generators as no-ops. | Programs with async logic will not execute correctly in engine |
| **Concurrency** | No model for threads, isolates, or parallel execution. | Concurrent programs cannot be interpreted |
| **File I/O** | No file system access beyond stdin/stdout/stderr/env. | Cannot read/write files |
| **Network I/O** | No HTTP, socket, or network support. | Cannot make network calls |
| **Serialization** | No JSON/XML/protobuf codec in std library. | Cannot serialize/deserialize data formats |
| **Error hierarchy** | Flat exception model; no typed error hierarchy. | Cannot catch specific error types meaningfully |
| **Preprocessor** | Ball has no preprocessor (by design — programs are structured data). | C++ #define/#include cannot round-trip |
| **Compile-time evaluation** | No constexpr/consteval/const evaluation in Ball. | C++ constexpr and Dart const expressions don't evaluate at compile time |
| **Reflection** | No mirror/RTTI system. | Cannot introspect types at runtime |

---

## Summary Tables

### C++ Coverage by Category

| Category | Features in C++17 | Covered by Ball | Coverage % |
|---|---|---|---|
| Primitive types | 15 | 8 | 53% |
| Compound types | 20 | 8 | 40% |
| Type qualifiers | 6 | 2 (metadata) | 33% |
| Type conversions | 7 | 6 | 86% |
| Arithmetic operators | 8 | 8 | 100% |
| Comparison operators | 7 | 6 | 86% |
| Logical operators | 3 | 3 | 100% |
| Bitwise operators | 6 | 6 | 100% |
| Assignment operators | 12 | 12 | 100% |
| Control flow | 14 | 11 | 79% |
| Functions/callables | 18 | 7 | 39% |
| Classes/OOP | 22 | 10 | 45% |
| Templates | 16 | 2 (metadata) | 13% |
| Memory management | 16 | 11 | 69% |
| Preprocessor | 10 | 0 | 0% |
| Concurrency | 12 | 0 | 0% |
| STL containers | 12 | 4 | 33% |
| STL algorithms | 20 | 10 | 50% |
| STL utilities | 15 | 3 | 20% |
| C++17 new features | 17 | 3 (metadata) | 18% |
| C++20 new features | 12 | 0 | 0% |
| **TOTAL** | **~278** | **~113** | **~41%** |

### Dart Coverage by Category

| Category | Features in Dart 3 | Covered by Ball | Coverage % |
|---|---|---|---|
| Primitive types | 11 | 8 | 73% |
| Collection types | 10 | 5 | 50% |
| Expressions/operators | 35 | 33 | 94% |
| Control flow | 19 | 18 | 95% |
| Functions/callables | 22 | 18 | 82% |
| Classes/OOP | 30 | 27 | 90% |
| Generics | 10 | 8 (syntax) | 80% |
| Null safety | 11 | 8 | 73% |
| Collections features | 16 | 12 | 75% |
| Async/concurrency | 18 | 4 (syntax-only) | 22% |
| Pattern matching | 14 | 3 (partial) | 21% |
| Dart 3.x features | 12 | 8 | 67% |
| dart:core | 15 | 8 | 53% |
| dart:math | 1 (module) | 1 | 100% |
| dart:collection | 1 (module) | 0.5 | 50% |
| dart:convert | 1 (module) | 0 | 0% |
| dart:async | 1 (module) | 0 | 0% |
| dart:io | 1 (module) | 0.3 | 30% |
| dart:typed_data | 1 (module) | 0.3 | 30% |
| Other dart: libraries | 6 | 0 | 0% |
| **TOTAL** | **~235** | **~162** | **~69%** |

### Top 20 Most Impactful Gaps (by priority)

| # | Gap | Affects | Effort | Impact |
|---|---|---|---|---|
| 1 | **Async/await execution** | Both | High | Cannot run any async code |
| 2 | **Generator execution** (yield/yield*) | Both | High | Cannot run generators |
| 3 | **Inheritance runtime** (super, virtual dispatch) | Both | High | OOP programs won't execute correctly |
| 4 | **Pattern matching semantics** (destructuring) | Dart | Medium | Dart 3 patterns are syntax-only |
| 5 | **Templates/generics at runtime** | Both | High | Generic code doesn't type-check |
| 6 | **File I/O** | Both | Medium | No file read/write |
| 7 | **Streams** | Dart | High | Core Dart async pattern unavailable |
| 8 | **Smart pointers** (unique_ptr, shared_ptr) | C++ | Medium | Modern C++ memory patterns missing |
| 9 | **Move semantics** | C++ | High | Core C++11+ feature unavailable |
| 10 | **RAII / deterministic destruction** | C++ | High | C++ resource management pattern missing |
| 11 | **JSON/serialization** | Both | Low-Med | No data interchange in std |
| 12 | **Function overloading** | C++ | Medium | C++ programs need name mangling |
| 13 | **Multiple inheritance** | C++ | Medium | C++ MI not possible |
| 14 | **Concepts** (C++20) | C++ | High | No constraint-based generics |
| 15 | **Coroutines** (C++20) | C++ | High | No coroutine support |
| 16 | **Isolates** | Dart | High | No Dart concurrency model |
| 17 | **DateTime/Duration** | Dart | Low | No time utilities |
| 18 | **Preprocessor/macros** | C++ | N/A | By design — Ball is structured data |
| 19 | **Null safety enforcement** | Dart | Medium | Sound null safety not enforced |
| 20 | **C++ string ops broken** | C++ | Low | `string_split/replace/replace_all` emit empty comments |

---

## Notes

- Ball deliberately excludes some features by design (preprocessor, goto, multiple parameters). These are architectural decisions, not gaps.
- Many C++ features are inherently incompatible with Ball's protobuf-based approach (preprocessor, RAII, compile-time evaluation). These would require fundamental schema changes.
- Dart coverage is much higher because Dart is the reference implementation language and Ball was designed with Dart-like semantics in mind.
- The `dart_std` module provides Dart-specific extensions that significantly close Dart gaps.
- C++ coverage would benefit from a `cpp_std` module (partially started) with C++-specific base functions.
