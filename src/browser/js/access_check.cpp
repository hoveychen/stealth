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

// v8::ObjectTemplate::SetAccessCheckCallbackAndHandler and
// v8::Isolate::SetFailedAccessCheckCallbackFunction: the mechanism Blink guards
// a cross-origin WindowProxy with, and the one thing a named interceptor cannot
// substitute for.
//
// An interceptor is consulted *during* a property lookup, which means anything
// that reaches a property without a lookup goes around it. Three readings on a
// cross-origin window turn on exactly that, all measured against Chrome 151
// (probe scratch/b90/expr-xo-messages.js):
//
//   JSON.stringify(w)  V8's stringifier looks `toJSON` up with
//                      PROTOTYPE_CHAIN_SKIP_INTERCEPTOR, so an interceptor
//                      never sees it and the object serialises as "{}". An
//                      access check is *not* skipped, which is why Chrome
//                      throws and names `toJSON` in the sentence.
//   'then' in w        `then` is an own key on both arms, and an own key is
//                      found before a [[NonMasking]] interceptor runs.
//   delete w.length    same, and the delete succeeds -- it removes the key.
//
// Two things keep this out of the V8 binding proper, exactly as for
// code_generation.cpp next door:
//
//   - the zig-v8 fork's C binding does not expose either entry point, and its
//     binding.cpp is compiled inside the V8 checkout, so adding it there means
//     cutting a new prebuilt release;
//   - the V8 headers are not on disk for an ordinary build (`make download-v8`
//     fetches libc_v8.a alone), so this file restates the declarations it needs
//     rather than including them. Transcribed from
//     include/v8-{template,callbacks,isolate,local-handle}.h of the pinned V8
//     (14.9.207.35, .github/actions/install/action.yml).
//
// The two handler configurations are passed straight through as pointers and
// never inspected here, so their layout stays defined in one place -- the Zig
// binding's NamedPropertyHandlerConfiguration, which SetNamedHandler already
// uses. Declaring them incomplete is enough to form the reference the V8 entry
// point takes, and an incomplete class name mangles the same as a complete one.
//
// Only the ABI lives here. The policy -- who may access what, and what the
// refusal says -- is in Zig, in browser/webapi/Window.zig.

namespace v8 {

class Context;
class Value;
class Object;
class Isolate;
class ObjectTemplate;
class NamedPropertyHandlerConfiguration;
class IndexedPropertyHandlerConfiguration;

// v8-local-handle.h; see code_generation.cpp for why this shape is safe to
// restate. Pointer-sized and trivially copyable, so it passes in one register.
template <class T>
class Local {
 public:
  T* slot_ = nullptr;
};

// v8-template.h
using AccessCheckCallback = bool (*)(Local<Context> accessing_context,
                                     Local<Object> accessed_object,
                                     Local<Value> data);

// v8-callbacks.h. The order is the ABI: V8 passes the enumerator by value.
enum AccessType {
  ACCESS_GET,
  ACCESS_SET,
  ACCESS_HAS,
  ACCESS_DELETE,
  ACCESS_KEYS
};

using FailedAccessCheckCallback = void (*)(Local<Object> target,
                                           AccessType type, Local<Value> data);

class ObjectTemplate {
 public:
  void SetAccessCheckCallbackAndHandler(
      AccessCheckCallback callback,
      const NamedPropertyHandlerConfiguration& named_handler,
      const IndexedPropertyHandlerConfiguration& indexed_handler,
      Local<Value> data);
};

class Isolate {
 public:
  void SetFailedAccessCheckCallbackFunction(FailedAccessCheckCallback);
};

}  // namespace v8

static_assert(sizeof(v8::Local<v8::Value>) == sizeof(void*),
              "v8::Local must be pointer-sized");

extern "C" {

// Implemented in Zig. True lets the access through; false refuses it and sends
// the operation to the handler, or to the failure callback below when the
// handler does not cover it.
bool lp_access_check__allow(const v8::Context* accessing_context,
                            const v8::Object* accessed_object);

// Implemented in Zig. Called once per refused operation the handler did not
// answer -- a symbol read, an `in`, a delete, a define. Its job is to throw;
// without it V8 answers undefined and the refusal is silent.
void lp_access_check__denied(const v8::Object* target, int access_type);

void lp_access_check__install_handler(
    v8::ObjectTemplate* object_template,
    const v8::NamedPropertyHandlerConfiguration* named_handler,
    const v8::IndexedPropertyHandlerConfiguration* indexed_handler);

void lp_access_check__install_failure_callback(v8::Isolate* isolate);

// The address V8 serialises into the snapshot for an access-checked template.
// A snapshot records every embedder callback as an index into an external
// reference table, and deserialising with a table that does not carry this one
// aborts the isolate with "Unknown external reference".
const void* lp_access_check__callback_address();
}

namespace {

bool accessCheck(v8::Local<v8::Context> accessing_context,
                 v8::Local<v8::Object> accessed_object, v8::Local<v8::Value>) {
  return lp_access_check__allow(accessing_context.slot_,
                                accessed_object.slot_);
}

void failedAccessCheck(v8::Local<v8::Object> target, v8::AccessType type,
                       v8::Local<v8::Value>) {
  lp_access_check__denied(target.slot_, static_cast<int>(type));
}

}  // namespace

void lp_access_check__install_handler(
    v8::ObjectTemplate* object_template,
    const v8::NamedPropertyHandlerConfiguration* named_handler,
    const v8::IndexedPropertyHandlerConfiguration* indexed_handler) {
  object_template->SetAccessCheckCallbackAndHandler(
      accessCheck, *named_handler, *indexed_handler, v8::Local<v8::Value>());
}

void lp_access_check__install_failure_callback(v8::Isolate* isolate) {
  isolate->SetFailedAccessCheckCallbackFunction(failedAccessCheck);
}

const void* lp_access_check__callback_address() {
  return reinterpret_cast<const void*>(accessCheck);
}
