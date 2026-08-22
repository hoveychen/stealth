// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// v8::Isolate::SetModifyCodeGenerationFromStringsCallback, which is how Blink
// gets a TrustedScript handed to `eval` or `new Function` unwrapped into its
// source string before V8 compiles it. Without the callback V8 does the
// ECMAScript-correct thing with a non-string source -- hands it straight back,
// uncompiled -- so a page that only ever passes eval a TrustedScript, which is
// what `require-trusted-types-for 'script'` forces, silently loses the code.
//
// Two things keep this out of the V8 binding proper:
//
//   - the zig-v8 fork's C binding does not expose the setter, and its
//     binding.cpp is compiled inside the V8 checkout, so adding it there means
//     cutting a new prebuilt release;
//   - the V8 headers are not on disk for an ordinary build. `make download-v8`
//     and CI fetch libc_v8.a alone -- the include tree only exists on a machine
//     that took the 10-minute source-build path -- so this file restates the
//     handful of declarations it needs instead of including them. They are
//     transcribed from include/v8-{isolate,callbacks,local-handle}.h of the
//     pinned V8 (14.9.207.35, .github/actions/install/action.yml).
//
// Only the ABI lives here. What counts as an unwrappable source is decided in
// Zig, in browser/webapi/trusted_types.zig.

namespace v8 {

class Context;
class Value;
class String;

// v8-local-handle.h: `class V8_TRIVIAL_ABI Local : public LocalBase<T>,
// public api_internal::StackAllocated<false>`, whose only non-empty base holds
// a single pointer. Trivially copyable and pointer-sized, so it passes in one
// register; empty is a null slot. Member names do not reach the ABI, but the
// namespace, the class name and the template shape all feed the mangled symbol
// this file links against.
template <class T>
class Local {
 public:
  T* slot_ = nullptr;
};

template <class T>
class MaybeLocal {
 public:
  Local<T> local_;
};

// v8-callbacks.h
struct ModifyCodeGenerationFromStringsResult {
  bool codegen_allowed = false;
  MaybeLocal<String> modified_source;
};

class Isolate {
 public:
  void SetModifyCodeGenerationFromStringsCallback(
      ModifyCodeGenerationFromStringsResult (*callback)(Local<Context>,
                                                        Local<Value>, bool));
};

}  // namespace v8

// The same two invariants binding.cpp asserts about handles. A V8 built with
// direct handles or a wider result struct would pass this file the wrong ABI,
// and the failure mode is a corrupt handle rather than a link error.
static_assert(sizeof(v8::Local<v8::Value>) == sizeof(void*),
              "v8::Local must be pointer-sized");
static_assert(sizeof(v8::ModifyCodeGenerationFromStringsResult) ==
                  2 * sizeof(void*),
              "ModifyCodeGenerationFromStringsResult must return in registers");

extern "C" {

// Implemented in Zig. Returns the source to compile in place of `source`, or
// null to leave V8's own handling of the value alone -- which, for anything
// that is not a string, means handing it back unexecuted.
const v8::String* lp_code_generation__unwrap_source(const v8::Context* context,
                                                    const v8::Value* source);

void lp_code_generation__install(v8::Isolate* isolate);
}

namespace {

v8::ModifyCodeGenerationFromStringsResult modifyCodeGeneration(
    v8::Local<v8::Context> context, v8::Local<v8::Value> source,
    bool is_code_like) {
  // Set for a host object marked by v8::Object::SetCodeLike(). Nothing in this
  // engine marks one, and Blink ignores the flag here too.
  (void)is_code_like;

  v8::ModifyCodeGenerationFromStringsResult result;
  // Never block. The callback's other job in Blink is enforcing CSP's
  // unsafe-eval, and this engine has no CSP to enforce; leaving this false
  // would turn every eval into an EvalError.
  result.codegen_allowed = true;

  const v8::String* unwrapped =
      lp_code_generation__unwrap_source(context.slot_, source.slot_);
  if (unwrapped != nullptr) {
    result.modified_source.local_.slot_ = const_cast<v8::String*>(unwrapped);
  }
  return result;
}

}  // namespace

void lp_code_generation__install(v8::Isolate* isolate) {
  isolate->SetModifyCodeGenerationFromStringsCallback(modifyCodeGeneration);
}
