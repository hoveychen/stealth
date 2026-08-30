// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
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

const std = @import("std");
const lp = @import("lightpanda");
const log = @import("../../log.zig");

const Frame = @import("../Frame.zig");
const Factory = @import("../Factory.zig");
const reflect = @import("../reflect.zig");

const js = @import("js.zig");
const Caller = @import("Caller.zig");
const Context = @import("Context.zig");

const v8 = js.v8;

pub fn Builder(comptime T: type) type {
    return struct {
        pub const @"type" = T;
        pub const ClassId = u16;

        pub fn constructor(comptime func: anytype, comptime opts: Constructor.Opts) Constructor {
            return Constructor.init(T, func, opts);
        }

        pub fn accessor(comptime getter: anytype, comptime setter: anytype, comptime opts: Caller.Function.Opts) Accessor {
            return Accessor.init(T, getter, setter, opts);
        }

        pub fn function(comptime func: anytype, comptime opts: Caller.Function.Opts) Function {
            return Function.init(T, func, opts);
        }

        pub fn indexed(comptime getter_func: anytype, comptime enumerator_func: anytype, comptime opts: Indexed.Opts) Indexed {
            return Indexed.init(T, getter_func, null, null, null, null, enumerator_func, opts);
        }

        pub fn indexedReadWrite(comptime getter_func: anytype, setter_func: anytype, deleter_func: anytype, query_func: anytype, comptime enumerator_func: anytype, comptime opts: Indexed.Opts) Indexed {
            return Indexed.init(T, getter_func, setter_func, deleter_func, query_func, null, enumerator_func, opts);
        }

        pub fn indexedFull(comptime getter_func: anytype, setter_func: anytype, deleter_func: anytype, query_func: anytype, definer_func: anytype, comptime enumerator_func: anytype, comptime opts: Indexed.Opts) Indexed {
            return Indexed.init(T, getter_func, setter_func, deleter_func, query_func, definer_func, enumerator_func, opts);
        }

        pub fn namedIndexed(comptime getter_func: anytype, setter_func: anytype, deleter_func: anytype, enumerator_func: anytype, query_func: anytype, comptime opts: NamedIndexed.Opts) NamedIndexed {
            return NamedIndexed.init(T, getter_func, setter_func, deleter_func, enumerator_func, query_func, null, null, opts);
        }

        pub fn namedIndexedFull(comptime getter_func: anytype, setter_func: anytype, deleter_func: anytype, enumerator_func: anytype, query_func: anytype, definer_func: anytype, descriptor_func: anytype, comptime opts: NamedIndexed.Opts) NamedIndexed {
            return NamedIndexed.init(T, getter_func, setter_func, deleter_func, enumerator_func, query_func, definer_func, descriptor_func, opts);
        }

        pub fn iterator(comptime func: anytype, comptime opts: Iterator.Opts) Iterator {
            return Iterator.init(T, func, opts);
        }

        pub fn callable(comptime func: anytype, comptime opts: Callable.Opts) Callable {
            return Callable.init(T, func, opts);
        }

        pub fn property(value: anytype, opts: Property.Opts) Property {
            switch (@typeInfo(@TypeOf(value))) {
                .bool => return Property.init(.{ .bool = value }, opts),
                .null => return Property.init(.null, opts),
                .comptime_int, .int => return Property.init(.{ .int = value }, opts),
                .comptime_float, .float => return Property.init(.{ .float = value }, opts),
                .pointer => |ptr| switch (ptr.size) {
                    .one => {
                        const one_info = @typeInfo(ptr.child);
                        if (one_info == .array and one_info.array.child == u8) {
                            return Property.init(.{ .string = value }, opts);
                        }
                    },
                    else => {},
                },
                else => {},
            }
            @compileError("Property for " ++ @typeName(@TypeOf(value)) ++ " hasn't been defined yet");
        }

        const PrototypeChainEntry = @import("TaggedOpaque.zig").PrototypeChainEntry;
        pub fn prototypeChain() [prototypeChainLength(T)]PrototypeChainEntry {
            var entries: [prototypeChainLength(T)]PrototypeChainEntry = undefined;

            entries[0] = .{ .offset = 0, .index = JsApiLookup.getId(T.JsApi) };

            if (entries.len == 1) {
                return entries;
            }

            var Prototype = T;
            inline for (entries[1..]) |*entry| {
                const Next = PrototypeType(Prototype).?;
                entry.* = .{
                    .index = JsApiLookup.getId(Next.JsApi),
                    .offset = Factory.protoOffset(Prototype),
                };
                Prototype = Next;
            }
            return entries;
        }
    };
}

pub const Constructor = struct {
    arity: c_int,
    func: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void,

    const Opts = struct {
        // When true, the constructor function receives `new.target` (as a
        // js.Function) as its first parameter. Used by HTMLElement to support
        // direct instantiation of custom elements via `new MyElement()`.
        new_target: bool = false,

        // Overrides the arity derived from the Zig signature. WebIDL says a
        // variadic argument contributes nothing to `length`, but a variadic and
        // a sequence argument are the same slice parameter here, so the ones
        // that are really variadic say so: `new CSSMathSum(a, b)` takes any
        // number of arguments and Chrome reports CSSMathSum.length === 0.
        arity: ?usize = null,
    };

    fn init(comptime T: type, comptime func: anytype, comptime opts: Opts) Constructor {
        return .{
            .arity = comptime opts.arity orelse Function.getArity(@TypeOf(func), if (opts.new_target) 1 else 0),
            .func = struct {
                fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                    const v8_isolate = v8.v8__FunctionCallbackInfo__GetIsolate(handle).?;
                    var caller: Caller = undefined;
                    if (!caller.init(v8_isolate)) {
                        return;
                    }
                    defer caller.deinit();

                    // Constructors are a JS-execution boundary, just like
                    // [CEReactions] methods. Open a reactions scope so any
                    // callbacks queued by the user's constructor body (or
                    // by attribute_changed reactions queued before invocation)
                    // drain at the constructor's exit, not later.
                    const ce_frame: ?*Frame = switch (caller.local.ctx.global) {
                        .frame => |frame| frame,
                        .worker => null,
                    };
                    const ce_checkpoint: usize = if (ce_frame) |frame| frame._ce_reactions.push() else 0;
                    defer if (ce_frame) |frame| frame._ce_reactions.popAndInvoke(ce_checkpoint, frame);

                    caller.constructor(T, func, handle.?, .{
                        .new_target = opts.new_target,
                        .required_args = comptime opts.arity orelse
                            Function.getArity(@TypeOf(func), if (opts.new_target) 1 else 0),
                    });
                }
            }.wrap,
        };
    }
};

pub const Function = struct {
    static: bool,
    arity: usize,
    noop: bool = false,
    wpt_only: bool = false,
    enumerable: bool = true,
    writable: bool = true,
    unforgeable: bool = false, // Web IDL [LegacyUnforgeable]
    js_name: ?[:0]const u8 = null,
    exposed: Caller.Function.Opts.Exposed = .both,
    cache: ?Caller.Function.Opts.Caching = null,
    rejects_bad_receiver: bool,
    func: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void,

    fn init(comptime T: type, comptime func: anytype, comptime opts: Caller.Function.Opts) Function {
        return .{
            .cache = opts.cache,
            .static = opts.static,
            .wpt_only = opts.wpt_only,
            .enumerable = opts.enumerable,
            .writable = opts.writable,
            .unforgeable = opts.unforgeable,
            .js_name = opts.js_name,
            .exposed = opts.exposed,
            .rejects_bad_receiver = returnsPromise(@TypeOf(func)),
            // Non-static methods receive `self` as their first param; static
            // methods don't, so don't skip the first param for them. `opts.arity`
            // overrides the derived value, which a variadic operation needs (see
            // Console's members, all of which report length 0).
            .arity = opts.arity orelse getArity(@TypeOf(func), if (opts.static) 0 else 1),
            .func = if (opts.noop) noopFunction else struct {
                fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                    // The arity is also the count Chrome refuses below, so the
                    // check and the reported `length` can never disagree.
                    const call_opts = comptime blk: {
                        var o = opts;
                        o.required_args = opts.arity orelse getArity(@TypeOf(func), if (opts.static) 0 else 1);
                        break :blk o;
                    };
                    Caller.Function.call(T, handle.?, func, call_opts);
                }
            }.wrap,
        };
    }

    pub fn noopFunction(_: ?*const v8.FunctionCallbackInfo) callconv(.c) void {}

    fn returnsPromise(comptime F: type) bool {
        const R = @typeInfo(F).@"fn".return_type orelse return false;
        return switch (@typeInfo(R)) {
            .error_union => |eu| eu.payload,
            else => R,
        } == js.Promise;
    }

    fn getArity(comptime T: type, comptime start: usize) usize {
        const Execution = js.Execution;

        const Page = @import("../Page.zig");
        const Session = @import("../Session.zig");

        var count: usize = 0;
        var params = @typeInfo(T).@"fn".params;
        for (params[start..]) |p| { // start at 1, skip self
            const PT = p.type.?;
            if (PT == *Frame or PT == *const Frame) {
                break;
            }

            if (PT == *Page or PT == *const Page) {
                break;
            }

            if (PT == *Execution or PT == *const Execution) {
                break;
            }

            if (PT == *Session or PT == *const Session) {
                break;
            }

            if (@typeInfo(PT) == .optional) {
                break;
            }

            // A slice of js.Value is always bound as variadic (see
            // Caller.getArgs) and variadics contribute 0 to length.
            if (@typeInfo(PT) == .pointer and @typeInfo(PT).pointer.size == .slice and @typeInfo(PT).pointer.child == js.Value) {
                break;
            }
            count += 1;
        }
        return count;
    }
};

pub const Accessor = struct {
    static: bool = false,
    deletable: bool = true,
    wpt_only: bool = false,
    unforgeable: bool = false, // Web IDL [LegacyUnforgeable]
    enumerable: bool = true,
    anonymous: bool = false,
    exposed: Caller.Function.Opts.Exposed = .both,
    cache: ?Caller.Function.Opts.Caching = null,
    getter: ?*const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void = null,
    setter: ?*const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void = null,

    fn init(comptime T: type, comptime getter: anytype, comptime setter: anytype, comptime opts: Caller.Function.Opts) Accessor {
        var accessor = Accessor{
            .cache = opts.cache,
            .static = opts.static,
            .wpt_only = opts.wpt_only,
            .deletable = opts.deletable,
            .unforgeable = opts.unforgeable,
            .enumerable = opts.enumerable,
            .anonymous = opts.anonymous,
            .exposed = opts.exposed,
        };

        if (@typeInfo(@TypeOf(getter)) != .null) {
            const getter_opts = if (opts.ce_reactions == false) opts else blk: {
                var o = opts;
                o.ce_reactions = false;
                break :blk o;
            };

            accessor.getter = struct {
                fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                    Caller.Function.call(T, handle.?, getter, getter_opts);
                }
            }.wrap;
        }

        if (@typeInfo(@TypeOf(setter)) != .null) {
            // The two halves share an Opts, and only this one refuses a value,
            // so only this one carries the lead-in that names the property.
            const setter_opts = blk: {
                var o = opts;
                o.is_setter = true;
                break :blk o;
            };

            accessor.setter = struct {
                fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                    Caller.Function.call(T, handle.?, setter, setter_opts);
                }
            }.wrap;
        }

        return accessor;
    }
};

pub const Indexed = struct {
    getter: *const fn (idx: u32, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32,
    enumerator: ?*const fn (handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32,
    setter: ?*const fn (idx: u32, c_value: ?*const v8.Value, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 = null,
    deleter: ?*const fn (idx: u32, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 = null,
    query: ?*const fn (idx: u32, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 = null,
    // v8 expects an Intercepted (u32) return; the stale void-returning
    // typedef in binding.h is papered over with a @ptrCast at install time.
    definer: ?*const fn (idx: u32, desc: ?*v8.PropertyDescriptor, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 = null,

    const Opts = struct {
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime getter: anytype, setter: anytype, deleter: anytype, query: anytype, definer: anytype, comptime enumerator: anytype, comptime opts: Opts) Indexed {
        var indexed = Indexed{
            .enumerator = null,
            .getter = struct {
                fn wrap(idx: u32, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 {
                    const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                    var caller: Caller = undefined;
                    if (!caller.init(v8_isolate)) {
                        return js.Intercepted.no;
                    }
                    defer caller.deinit();

                    return caller.getIndex(T, getter, idx, handle.?, .{
                        .as_typed_array = opts.as_typed_array,
                        .null_as_undefined = opts.null_as_undefined,
                    });
                }
            }.wrap,
        };

        if (@typeInfo(@TypeOf(enumerator)) != .null) {
            indexed.enumerator = struct {
                fn wrap(handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 {
                    const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                    var caller: Caller = undefined;
                    if (!caller.init(v8_isolate)) {
                        return js.Intercepted.no;
                    }
                    defer caller.deinit();
                    return caller.getEnumerator(T, enumerator, handle.?, .{});
                }
            }.wrap;
        }

        if (@typeInfo(@TypeOf(setter)) != .null) {
            indexed.setter = struct {
                fn wrap(idx: u32, c_value: ?*const v8.Value, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 {
                    const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                    var caller: Caller = undefined;
                    if (!caller.init(v8_isolate)) {
                        return js.Intercepted.no;
                    }
                    defer caller.deinit();

                    return caller.setIndex(T, setter, idx, c_value.?, handle.?, .{
                        .as_typed_array = opts.as_typed_array,
                        .null_as_undefined = opts.null_as_undefined,
                    });
                }
            }.wrap;
        }

        if (@typeInfo(@TypeOf(deleter)) != .null) {
            indexed.deleter = struct {
                fn wrap(idx: u32, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 {
                    const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                    var caller: Caller = undefined;
                    if (!caller.init(v8_isolate)) {
                        return js.Intercepted.no;
                    }
                    defer caller.deinit();

                    return caller.deleteOrDefineIndex(T, deleter, idx, handle.?, .{
                        .as_typed_array = opts.as_typed_array,
                        .null_as_undefined = opts.null_as_undefined,
                    });
                }
            }.wrap;
        }

        if (@typeInfo(@TypeOf(query)) != .null) {
            indexed.query = struct {
                fn wrap(idx: u32, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 {
                    const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                    var caller: Caller = undefined;
                    if (!caller.init(v8_isolate)) {
                        return js.Intercepted.no;
                    }
                    defer caller.deinit();

                    return caller.getIndexQuery(T, query, idx, handle.?);
                }
            }.wrap;
        }

        if (@typeInfo(@TypeOf(definer)) != .null) {
            indexed.definer = struct {
                fn wrap(idx: u32, _: ?*v8.PropertyDescriptor, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 {
                    const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                    var caller: Caller = undefined;
                    if (!caller.init(v8_isolate)) {
                        return js.Intercepted.no;
                    }
                    defer caller.deinit();

                    // same (self, index) -> bool shape as a deleter
                    return caller.deleteOrDefineIndex(T, definer, idx, handle.?, .{});
                }
            }.wrap;
        }

        return indexed;
    }
};

pub const NamedIndexed = struct {
    getter: *const fn (c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32,
    setter: ?*const fn (c_name: ?*const v8.Name, c_value: ?*const v8.Value, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 = null,
    deleter: ?*const fn (c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 = null,
    query: ?*const fn (c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 = null,
    // v8 expects an Intercepted (u32) return; the stale void-returning
    // typedefs in binding.h are papered over with a @ptrCast at install time.
    definer: ?*const fn (c_name: ?*const v8.Name, desc: ?*v8.PropertyDescriptor, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 = null,
    descriptor: ?*const fn (c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 = null,
    enumerator: ?*const fn (handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 = null,

    const Opts = struct {
        as_typed_array: bool = false,
        null_as_undefined: bool = false,
        // Mirrors [CEReactions] on a named-property setter/deleter (e.g.,
        // HTMLElement.dataset, which proxies setAttribute/removeAttribute).
        // Only applies to setter and deleter; getters don't mutate.
        ce_reactions: bool = false,
    };

    fn init(comptime T: type, comptime getter: anytype, setter: anytype, deleter: anytype, enumerator: anytype, query: anytype, definer: anytype, descriptor: anytype, comptime opts: Opts) NamedIndexed {
        const getter_fn = struct {
            fn wrap(c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 {
                const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                var caller: Caller = undefined;
                if (!caller.init(v8_isolate)) {
                    return js.Intercepted.no;
                }
                defer caller.deinit();

                return caller.getNamedIndex(T, getter, c_name.?, handle.?, .{
                    .as_typed_array = opts.as_typed_array,
                    .null_as_undefined = opts.null_as_undefined,
                });
            }
        }.wrap;

        const setter_fn = if (@typeInfo(@TypeOf(setter)) == .null) null else struct {
            fn wrap(c_name: ?*const v8.Name, c_value: ?*const v8.Value, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 {
                const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                var caller: Caller = undefined;
                if (!caller.init(v8_isolate)) {
                    return js.Intercepted.no;
                }
                defer caller.deinit();

                const ce_frame: ?*Frame = if (comptime opts.ce_reactions) switch (caller.local.ctx.global) {
                    .frame => |frame| frame,
                    .worker => null,
                } else null;
                var ce_checkpoint: usize = undefined;
                if (comptime opts.ce_reactions) {
                    if (ce_frame) |frame| ce_checkpoint = frame._ce_reactions.push();
                }
                defer if (comptime opts.ce_reactions) {
                    if (ce_frame) |frame| frame._ce_reactions.popAndInvoke(ce_checkpoint, frame);
                };

                return caller.setNamedIndex(T, setter, c_name.?, c_value.?, handle.?, .{
                    .as_typed_array = opts.as_typed_array,
                    .null_as_undefined = opts.null_as_undefined,
                });
            }
        }.wrap;

        const deleter_fn = if (@typeInfo(@TypeOf(deleter)) == .null) null else struct {
            fn wrap(c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 {
                const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                var caller: Caller = undefined;
                if (!caller.init(v8_isolate)) {
                    return js.Intercepted.no;
                }
                defer caller.deinit();

                const ce_frame: ?*Frame = if (comptime opts.ce_reactions) switch (caller.local.ctx.global) {
                    .frame => |frame| frame,
                    .worker => null,
                } else null;
                var ce_checkpoint: usize = undefined;
                if (comptime opts.ce_reactions) {
                    if (ce_frame) |frame| ce_checkpoint = frame._ce_reactions.push();
                }
                defer if (comptime opts.ce_reactions) {
                    if (ce_frame) |frame| frame._ce_reactions.popAndInvoke(ce_checkpoint, frame);
                };

                return caller.deleteOrDefineNamedIndex(T, deleter, c_name.?, handle.?, .{
                    .as_typed_array = opts.as_typed_array,
                    .null_as_undefined = opts.null_as_undefined,
                });
            }
        }.wrap;

        const definer_fn = if (@typeInfo(@TypeOf(definer)) == .null) null else struct {
            fn wrap(c_name: ?*const v8.Name, _: ?*v8.PropertyDescriptor, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 {
                const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                var caller: Caller = undefined;
                if (!caller.init(v8_isolate)) {
                    return js.Intercepted.no;
                }
                defer caller.deinit();

                // same (self, name) -> bool shape as a deleter
                return caller.deleteOrDefineNamedIndex(T, definer, c_name.?, handle.?, .{});
            }
        }.wrap;

        const descriptor_fn = if (@typeInfo(@TypeOf(descriptor)) == .null) null else struct {
            fn wrap(c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 {
                const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                var caller: Caller = undefined;
                if (!caller.init(v8_isolate)) {
                    return js.Intercepted.no;
                }
                defer caller.deinit();

                // same (self, name) -> value shape as a getter; the returned
                // struct is converted to a JS property descriptor object
                return caller.getNamedIndex(T, descriptor, c_name.?, handle.?, .{});
            }
        }.wrap;

        const enumerator_fn = if (@typeInfo(@TypeOf(enumerator)) == .null) null else struct {
            fn wrap(handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 {
                const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                var caller: Caller = undefined;
                if (!caller.init(v8_isolate)) {
                    return js.Intercepted.no;
                }
                defer caller.deinit();

                return caller.getEnumerator(T, enumerator, handle.?, .{});
            }
        }.wrap;

        const query_fn = if (@typeInfo(@TypeOf(query)) == .null) null else struct {
            fn wrap(c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 {
                const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                var caller: Caller = undefined;
                if (!caller.init(v8_isolate)) {
                    return js.Intercepted.no;
                }
                defer caller.deinit();

                return caller.getNamedQuery(T, query, c_name.?, handle.?);
            }
        }.wrap;

        return .{
            .getter = getter_fn,
            .setter = setter_fn,
            .deleter = deleter_fn,
            .query = query_fn,
            .definer = definer_fn,
            .descriptor = descriptor_fn,
            .enumerator = enumerator_fn,
        };
    }
};

pub const Iterator = struct {
    func: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void,
    async: bool,
    // What `String(obj[Symbol.iterator])` reports. Chrome names the function
    // after the default iterator the interface declares -- "values" for a
    // list, "entries" for a maplike -- and leaving it unset prints an anonymous
    // `function () { [native code] }`, which no browser does. Null keeps that
    // older behaviour for the classes whose Chrome name has not been measured
    // yet.
    js_name: ?[:0]const u8,

    const Opts = struct {
        async: bool = false,
        null_as_undefined: bool = false,
        js_name: ?[:0]const u8 = null,
    };

    fn init(comptime T: type, comptime struct_or_func: anytype, comptime opts: Opts) Iterator {
        if (@typeInfo(@TypeOf(struct_or_func)) == .type) {
            return .{
                .async = opts.async,
                .js_name = opts.js_name,
                .func = struct {
                    fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                        const info = Caller.FunctionCallbackInfo{ .handle = handle.? };
                        info.getReturnValue().set(info.getThis());
                    }
                }.wrap,
            };
        }

        return .{
            .async = opts.async,
            .js_name = opts.js_name,
            .func = struct {
                fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                    return Caller.Function.call(T, handle.?, struct_or_func, .{
                        .null_as_undefined = opts.null_as_undefined,
                    });
                }
            }.wrap,
        };
    }
};

pub const Callable = struct {
    func: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void,

    const Opts = struct {
        null_as_undefined: bool = false,
    };

    fn init(comptime T: type, comptime func: anytype, comptime opts: Opts) Callable {
        return .{ .func = struct {
            fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
                Caller.Function.call(T, handle.?, func, .{
                    .null_as_undefined = opts.null_as_undefined,
                });
            }
        }.wrap };
    }
};

pub const Property = struct {
    value: Value,
    template: bool,
    readonly: bool,

    const Value = union(enum) {
        null,
        int: i64,
        float: f64,
        bool: bool,
        string: []const u8,
    };

    const Opts = struct {
        template: bool,
        readonly: bool = true,
    };

    fn init(value: Value, opts: Opts) Property {
        return .{
            .value = value,
            .template = opts.template,
            .readonly = opts.readonly,
        };
    }
};

pub fn unknownWindowPropertyCallback(c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 {
    const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;

    // During snapshot creation, there's no Context in embedder data yet.
    // I hate this check, but there doesn't seem to be a way to add this method
    // to the global, without triggering it during snapshot creation.
    const v8_context = v8.v8__Isolate__GetCurrentContext(v8_isolate) orelse return js.Intercepted.no;
    const ctx: *Context = @ptrCast(@alignCast(v8.v8__Context__GetAlignedPointerFromEmbedderData(v8_context, 1) orelse return js.Intercepted.no));

    var caller: Caller = undefined;
    caller.initWithContext(ctx, v8_context);
    defer caller.deinit();

    const local = &caller.local;

    var hs: js.HandleScope = undefined;
    hs.init(local.isolate);
    defer hs.deinit();

    const property: []const u8 = js.String.toSlice(.{ .local = local, .handle = @ptrCast(c_name.?) }) catch {
        return js.Intercepted.no;
    };

    // Only Page contexts have document.getElementById lookup
    switch (local.ctx.global) {
        .frame => |frame| {
            const document = frame.document;
            if (document.getElementById(property, frame)) |el| {
                const js_val = local.zigValueToJs(el, .{}) catch return js.Intercepted.no;
                var pc = Caller.PropertyCallbackInfo{ .handle = handle.? };
                pc.getReturnValue().set(js_val);
                return js.Intercepted.yes;
            }
        },
        .worker => {}, // no global lookup in a worker
    }

    if (comptime lp.IS_DEBUG) {
        if (std.mem.startsWith(u8, property, "__")) {
            // some frameworks will extend built-in types using a __ prefix
            // these should always be safe to ignore.
            return js.Intercepted.no;
        }

        const ignored = std.StaticStringMap(void).initComptime(.{
            .{ "Deno", {} },
            .{ "process", {} },
            .{ "ShadyDOM", {} },
            .{ "ShadyCSS", {} },

            // a lot of sites seem to like having their own window.config.
            .{ "config", {} },

            .{ "litNonce", {} },
            .{ "litHtmlVersions", {} },
            .{ "litElementVersions", {} },
            .{ "litHtmlPolyfillSupport", {} },
            .{ "litElementHydrateSupport", {} },
            .{ "litElementPolyfillSupport", {} },
            .{ "reactiveElementVersions", {} },

            .{ "recaptcha", {} },
            .{ "grecaptcha", {} },
            .{ "___grecaptcha_cfg", {} },
            .{ "__recaptcha_api", {} },
            .{ "__google_recaptcha_client", {} },

            .{ "CLOSURE_FLAGS", {} },
            .{ "__REACT_DEVTOOLS_GLOBAL_HOOK__", {} },
            .{ "ApplePaySession", {} },
        });
        if (!ignored.has(property)) {
            var buf: [2048]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "Window:{s}", .{property}) catch return js.Intercepted.no;
            logUnknownProperty(local, key) catch return js.Intercepted.no;
        }
    }

    return js.Intercepted.no;
}

// Only used for debugging
pub fn unknownObjectPropertyCallback(comptime JsApi: type) *const fn (?*const v8.Name, ?*const v8.PropertyCallbackInfo) callconv(.c) u32 {
    if (comptime !lp.IS_DEBUG) {
        @compileError("unknownObjectPropertyCallback should only be used in debug builds");
    }

    return struct {
        fn wrap(c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 {
            const v8_isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;

            var caller: Caller = undefined;
            if (!caller.init(v8_isolate)) {
                return js.Intercepted.no;
            }
            defer caller.deinit();

            const local = &caller.local;

            var hs: js.HandleScope = undefined;
            hs.init(local.isolate);
            defer hs.deinit();

            const property: []const u8 = js.String.toSlice(.{ .local = local, .handle = @ptrCast(c_name.?) }) catch {
                return js.Intercepted.no;
            };

            if (std.mem.startsWith(u8, property, "__")) {
                // some frameworks will extend built-in types using a __ prefix
                // these should always be safe to ignore.
                return js.Intercepted.no;
            }

            if (std.mem.startsWith(u8, property, "jQuery")) {
                return js.Intercepted.no;
            }

            if (JsApi == @import("../webapi/cdata/Text.zig").JsApi or JsApi == @import("../webapi/cdata/Comment.zig").JsApi) {
                if (std.mem.eql(u8, property, "tagName")) {
                    // knockout does this, a lot.
                    return js.Intercepted.no;
                }
            }

            if (JsApi == @import("../webapi/element/Html.zig").JsApi or JsApi == @import("../webapi/Element.zig").JsApi or JsApi == @import("../webapi/element/html/Custom.zig").JsApi) {
                // react ?
                if (std.mem.eql(u8, property, "props")) return js.Intercepted.no;
                if (std.mem.eql(u8, property, "hydrated")) return js.Intercepted.no;
                if (std.mem.eql(u8, property, "isHydrated")) return js.Intercepted.no;
            }

            if (JsApi == @import("../webapi/Console.zig").JsApi) {
                if (std.mem.eql(u8, property, "firebug")) return js.Intercepted.no;
            }

            const ignored = std.StaticStringMap(void).initComptime(.{});
            if (!ignored.has(property)) {
                var buf: [2048]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "{s}:{s}", .{ if (@hasDecl(JsApi.Meta, "name")) JsApi.Meta.name else @typeName(JsApi), property }) catch return js.Intercepted.no;
                logUnknownProperty(local, key) catch return js.Intercepted.no;
            }
            return js.Intercepted.no;
        }
    }.wrap;
}

fn logUnknownProperty(local: *const js.Local, key: []const u8) !void {
    const ctx = local.ctx;
    const gop = try ctx.unknown_properties.getOrPut(ctx.arena.allocator(), key);
    if (gop.found_existing) {
        gop.value_ptr.count += 1;
    } else {
        gop.key_ptr.* = try ctx.arena.dupe(u8, key);
        gop.value_ptr.* = .{
            .count = 1,
            .first_stack = try ctx.arena.dupe(u8, (try local.stackTrace()) orelse "???"),
        };
    }
}

// Returns the member with its callback wrapped in a recorder that names it, so
// a run can be asked afterwards which parts of the surface the page actually
// reached. `unknown_properties` above answers the opposite question -- what we
// don't have -- and a detector that reads a member we do have and dislikes the
// answer shows up in neither the unknown list nor any test we would think to
// write. Only the read half is wrapped: a write is the page telling us
// something, not asking.
//
// Both the template and the snapshot's external-reference table have to name
// the same function pointer, so Snapshot calls this on both paths rather than
// wrapping at the point of attachment. Outside Debug it hands the member back
// untouched and no wrapper exists at all.
pub fn logReads(comptime JsApi: type, comptime member: []const u8, comptime value: anytype) @TypeOf(value) {
    if (comptime lp.IS_DEBUG == false) {
        return value;
    }

    const interface: []const u8 = if (@hasDecl(JsApi.Meta, "name")) JsApi.Meta.name else @typeName(JsApi);
    const key: []const u8 = interface ++ "." ++ member;

    var wrapped = value;
    switch (@TypeOf(value)) {
        Accessor => {
            const getter = value.getter orelse return value;
            wrapped.getter = recordingCallback(key, getter);
        },
        Function => wrapped.func = recordingOperationCallback(key, value.func),
        NamedIndexed => {
            // A named-property interceptor has no member name of its own: the
            // declaration is `[str]` (or `[]`), and the question the page asked
            // is the name it passed. So the key is the surface that answered --
            // `CSSStyleDeclaration[str]` -- and the name rides along as the
            // argument, the same way an operation's first argument does.
            //
            // This half is why "getComputedStyle, 126 times" could not be
            // turned into a list of properties: the accessor that hands out the
            // declaration is wrapped, every read off it was not.
            wrapped.getter = recordingNamedCallback(interface ++ member, value.getter);
        },
        else => @compileError("logReads: " ++ @typeName(@TypeOf(value))),
    }
    return wrapped;
}

// The shapes of first argument worth keying a read on. A media query and a
// WebGL enum are both "the question the page asked"; an object argument is a
// value we would have to serialize before it said anything, and none of the
// calls this was built to read take one.
const ReadArgument = union(enum) {
    string: []const u8,
    number: f64,
};

// How much of a string argument survives into the key. Long enough for the
// media queries and MIME types this exists to read, short enough that one
// stylesheet passed to `CSS.supports` doesn't own the line.
const max_argument_len = 96;

// Renders `Interface.member(arg)` into `buf`, or hands back the bare member
// when there is no argument of a shape we key on.
//
// Bytes outside printable ASCII become '.': the result goes into a logfmt
// value, and log.writeString sends any value holding one control byte through
// its base64 branch, which would cost the reader the whole line rather than
// the one argument.
fn formatArgumentKey(buf: []u8, key: []const u8, arg: ?ReadArgument) []const u8 {
    const a = arg orelse return key;

    var w = std.Io.Writer.fixed(buf);
    w.writeAll(key) catch return key;
    switch (a) {
        .string => |s| {
            const text = s[0..@min(s.len, max_argument_len)];
            w.writeAll("(\"") catch return key;
            for (text) |b| {
                w.writeByte(switch (b) {
                    0x20...0x7e => b,
                    else => '.',
                }) catch return key;
            }
            if (text.len != s.len) {
                w.writeAll("...") catch return key;
            }
            w.writeAll("\")") catch return key;
        },
        .number => |n| {
            // A WebGL enum reads as 37446, not 3.7446e4, and `getParameter`
            // asked 152 times is a list of enums or it is nothing.
            if (@floor(n) == n and @abs(n) < 1e15) {
                w.print("({d})", .{@as(i64, @intFromFloat(n))}) catch return key;
            } else {
                w.print("({d})", .{n}) catch return key;
            }
        },
    }
    return w.buffered();
}

fn recordingCallback(
    comptime key: []const u8,
    comptime inner: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void,
) *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void {
    return struct {
        fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
            // Checked per call rather than per build: this fires on every
            // accessor and operation the page touches, which for a page doing
            // real work is tens of thousands of times.
            if (log.enabled(.prop_read, .debug)) {
                const isolate = v8.v8__FunctionCallbackInfo__GetIsolate(handle).?;
                if (Context.fromIsolate(.{ .handle = isolate })) |found| {
                    found[0].recordPropertyRead(key);
                }
            }
            inner(handle);
        }
    }.wrap;
}

// The operation half of the same idea. An accessor is the whole question --
// `navigator.webdriver` has nothing else to say -- but an operation's question
// lives in its arguments, and the plain log answers "matchMedia, 431 times"
// when what a diff needs is which 431 queries. Behind its own scope because
// the key is now built per call rather than being a comptime string.
fn recordingOperationCallback(
    comptime key: []const u8,
    comptime inner: *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void,
) *const fn (?*const v8.FunctionCallbackInfo) callconv(.c) void {
    return struct {
        fn wrap(handle: ?*const v8.FunctionCallbackInfo) callconv(.c) void {
            if (log.enabled(.prop_read, .debug)) {
                const isolate = v8.v8__FunctionCallbackInfo__GetIsolate(handle).?;
                if (Context.fromIsolate(.{ .handle = isolate })) |found| {
                    const ctx, const v8_context = found;
                    if (log.enabled(.prop_arg, .debug)) {
                        recordWithArgument(ctx, v8_context, key, handle.?);
                    } else {
                        ctx.recordPropertyRead(key);
                    }
                }
            }
            inner(handle);
        }
    }.wrap;
}

// Keys the read on the call's first argument. Only the first: `matchMedia`,
// `getParameter` and `canPlayType` each ask their whole question there, and a
// key that grew with the argument list would stop being the one thing two arms
// can be lined up on.
fn recordWithArgument(
    ctx: *Context,
    v8_context: *const v8.Context,
    comptime key: []const u8,
    handle: *const v8.FunctionCallbackInfo,
) void {
    const info: Caller.FunctionCallbackInfo = .{ .handle = handle };
    if (info.length() == 0) {
        return ctx.recordPropertyRead(key);
    }

    var hs: js.HandleScope = undefined;
    hs.init(ctx.isolate);
    defer hs.deinit();

    const local: js.Local = .{
        .ctx = ctx,
        .handle = v8_context,
        .isolate = ctx.isolate,
        .call_arena = ctx.call_arena,
    };
    const value = info.getArg(0, &local);

    // Room for more than the cap so a source string longer than the cap comes
    // back longer than the cap: WriteUtf8 stops on a whole character, and a
    // buffer sized exactly to the cap would report a truncated argument as one
    // that happened to end there.
    var text: [max_argument_len + 8]u8 = undefined;
    const arg: ReadArgument = if (value.isString()) |str|
        .{ .string = str.toSliceWithBuf(&text) }
    else if (value.isNumber())
        .{ .number = value.toF64() catch return ctx.recordPropertyRead(key) }
    else
        // An object, a callback, a boolean: nothing a key could carry without
        // serializing it, and none of the reads this was built for pass one.
        return ctx.recordPropertyRead(key);

    var buf: [key.len + max_argument_len + 8]u8 = undefined;
    ctx.recordPropertyReadDynamic(formatArgumentKey(&buf, key, arg), key);
}

// The named-property interceptor's version of the same recorder. It reads the
// name straight off the callback rather than through `Caller`: the wrapper runs
// before the real getter has entered a scope of its own, and `WriteUtf8` on an
// already-live handle needs neither.
//
// Bare key without `prop_arg`, for the same reason operations take that
// bargain: keyed by name the key set stops being bounded by our surface and
// starts being bounded by whatever the page asks for.
fn recordingNamedCallback(
    comptime key: []const u8,
    comptime inner: *const fn (?*const v8.Name, ?*const v8.PropertyCallbackInfo) callconv(.c) u32,
) *const fn (?*const v8.Name, ?*const v8.PropertyCallbackInfo) callconv(.c) u32 {
    return struct {
        fn wrap(c_name: ?*const v8.Name, handle: ?*const v8.PropertyCallbackInfo) callconv(.c) u32 {
            if (log.enabled(.prop_read, .debug)) {
                const isolate = v8.v8__PropertyCallbackInfo__GetIsolate(handle).?;
                if (Context.fromIsolate(.{ .handle = isolate })) |found| {
                    recordNamedRead(found[0], isolate, key, c_name);
                }
            }
            return inner(c_name, handle);
        }
    }.wrap;
}

fn recordNamedRead(
    ctx: *Context,
    isolate: *v8.Isolate,
    comptime key: []const u8,
    c_name: ?*const v8.Name,
) void {
    const name = c_name orelse return ctx.recordPropertyRead(key);
    if (!log.enabled(.prop_arg, .debug)) {
        return ctx.recordPropertyRead(key);
    }

    // The handler is installed with kOnlyInterceptStrings, so the name is a
    // string every time it reaches here.
    var text: [max_argument_len + 8]u8 = undefined;
    const written = v8.v8__String__WriteUtf8(
        @ptrCast(name),
        isolate,
        &text,
        text.len,
        v8.NO_NULL_TERMINATION | v8.REPLACE_INVALID_UTF8,
    );
    if (written < 0) {
        return ctx.recordPropertyRead(key);
    }

    var buf: [key.len + max_argument_len + 8]u8 = undefined;
    const arg: ReadArgument = .{ .string = text[0..@intCast(written)] };
    ctx.recordPropertyReadDynamic(formatArgumentKey(&buf, key, arg), key);
}

// Given a Type, returns the length of the prototype chain, including self
fn prototypeChainLength(comptime T: type) usize {
    var l: usize = 1;
    var Next = T;
    while (PrototypeType(Next)) |N| {
        Next = N;
        l += 1;
    }
    return l;
}

// Given a Type, gets its prototype Type (if any)
fn PrototypeType(comptime T: type) ?type {
    return reflect.Proto(T);
}

fn flattenTypes(comptime Types: []const type) [countFlattenedTypes(Types)]type {
    @setEvalBranchQuota(10_000);
    var index: usize = 0;
    var flat: [countFlattenedTypes(Types)]type = undefined;
    for (Types) |T| {
        if (@hasDecl(T, "registerTypes")) {
            for (T.registerTypes()) |TT| {
                flat[index] = TT.JsApi;
                index += 1;
            }
        } else {
            flat[index] = T.JsApi;
            index += 1;
        }
    }
    return flat;
}

fn countFlattenedTypes(comptime Types: []const type) usize {
    @setEvalBranchQuota(10_000);
    var c: usize = 0;
    for (Types) |T| {
        c += if (@hasDecl(T, "registerTypes")) T.registerTypes().len else 1;
    }
    return c;
}

//  T => T
// *T => T
pub fn Struct(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .@"struct" => T,
        .pointer => |ptr| ptr.child,
        else => @compileError("Expecting Struct or *Struct, got: " ++ @typeName(T)),
    };
}

pub const JsApiLookup = struct {
    /// Integer type we use for `JsApiLookup` enum. Can be u8 at min.
    pub const BackingInt = std.math.IntFittingRange(0, @max(std.math.maxInt(u8), JsApis.len));

    /// Imagine we have a type `Cat` which has a getter:
    ///
    ///    fn get_owner(self: *Cat) *Owner {
    ///        return self.owner;
    ///    }
    ///
    /// When we execute `caller.getter`, we'll end up doing something like:
    ///
    ///    const res = @call(.auto, Cat.get_owner, .{cat_instance});
    ///
    /// How do we turn `res`, which is an *Owner, into something we can return
    /// to v8? We need the ObjectTemplate associated with Owner. How do we
    /// get that? Well, we store all the ObjectTemplates in an array that's
    /// tied to env. So we do something like:
    ///
    ///    env.templates[index_of_owner].initInstance(...);
    ///
    /// But how do we get that `index_of_owner`? `Index` is an enum
    /// that looks like:
    ///
    ///    pub const Enum = enum(BackingInt) {
    ///        cat = 0,
    ///        owner = 1,
    ///        ...
    ///    }
    ///
    /// (`BackingInt` is calculated at comptime regarding to interfaces we have)
    /// So to get the template index of `owner`, simply do:
    ///
    ///    const index_id = types.getId(@TypeOf(res));
    ///
    pub const Enum = blk: {
        // std.simd.iota loops once per interface, so the quota has to grow
        // with the interface list.
        @setEvalBranchQuota(JsApis.len * 8);
        var names: [JsApis.len][:0]const u8 = undefined;
        for (JsApis, 0..) |JsApi, i| {
            names[i] = @typeName(JsApi);
        }

        break :blk @Enum(BackingInt, .exhaustive, &names, &std.simd.iota(BackingInt, JsApis.len));
    };

    /// Returns a boolean indicating if a type exist in the lookup.
    pub inline fn has(t: type) bool {
        return @hasField(Enum, @typeName(t));
    }

    /// Returns the `Enum` for the given type.
    pub inline fn getIndex(t: type) Enum {
        return @field(Enum, @typeName(t));
    }

    /// Returns the ID for the given type.
    pub inline fn getId(t: type) BackingInt {
        return @intFromEnum(getIndex(t));
    }
};

pub const SubType = enum {
    @"error",
    array,
    arraybuffer,
    dataview,
    date,
    generator,
    iterator,
    map,
    node,
    promise,
    proxy,
    regexp,
    set,
    typedarray,
    wasmvalue,
    weakmap,
    weakset,
    webassemblymemory,
};

// APIs for Page/Window contexts. Used by Snapshot.zig for Page snapshot creation.
pub const PageJsApis = flattenTypes(&.{
    @import("../webapi/AbortController.zig"),
    @import("../webapi/AbortSignal.zig"),
    @import("../webapi/CData.zig"),
    @import("../webapi/cdata/Comment.zig"),
    @import("../webapi/cdata/Text.zig"),
    @import("../webapi/cdata/CDATASection.zig"),
    @import("../webapi/cdata/ProcessingInstruction.zig"),
    @import("../webapi/collections.zig"),
    @import("../webapi/Console.zig"),
    @import("../webapi/Crypto.zig"),
    @import("../webapi/Permissions.zig"),
    @import("../webapi/StorageManager.zig"),
    @import("../webapi/CSS.zig"),
    @import("../webapi/css/CSSRule.zig"),
    @import("../webapi/css/CSSRuleList.zig"),
    @import("../webapi/css/rules.zig"),
    @import("../webapi/css/iterators.zig"),
    @import("../webapi/css/typed_om.zig"),
    @import("../webapi/css/StyleSheet.zig"),
    @import("../webapi/css/MediaList.zig"),
    @import("../webapi/css/CSSStyleDeclaration.zig"),
    @import("../webapi/css/CSSStyleRule.zig"),
    @import("../webapi/css/CSSStyleSheet.zig"),
    @import("../webapi/css/FontFace.zig"),
    @import("../webapi/css/FontFaceSet.zig"),
    @import("../webapi/css/highlights.zig"),
    @import("../webapi/css/MediaQueryList.zig"),
    @import("../webapi/css/StyleSheetList.zig"),
    @import("../webapi/Document.zig"),
    @import("../webapi/HTMLDocument.zig"),
    @import("../webapi/XMLDocument.zig"),
    @import("../webapi/History.zig"),
    @import("../webapi/KeyValueList.zig"),
    @import("../webapi/DocumentFragment.zig"),
    @import("../webapi/DocumentType.zig"),
    @import("../webapi/ShadowRoot.zig"),
    @import("../webapi/DOMException.zig"),
    @import("../webapi/QuotaExceededError.zig"),
    @import("../webapi/DOMError.zig"),
    @import("../webapi/ClipboardItem.zig"),
    @import("../webapi/EyeDropper.zig"),
    @import("../webapi/IdleDetector.zig"),
    @import("../webapi/EditContext.zig"),
    @import("../webapi/TextFormat.zig"),
    @import("../webapi/InputDeviceCapabilities.zig"),
    @import("../webapi/Profiler.zig"),
    @import("../webapi/DOMImplementation.zig"),
    @import("../webapi/DOMTreeWalker.zig"),
    @import("../webapi/DOMNodeIterator.zig"),
    @import("../webapi/DOMRectReadOnly.zig"),
    @import("../webapi/DOMRect.zig"),
    @import("../webapi/DOMMatrixReadOnly.zig"),
    @import("../webapi/DOMMatrix.zig"),
    @import("../webapi/DOMPointReadOnly.zig"),
    @import("../webapi/DOMPoint.zig"),
    @import("../webapi/DOMQuad.zig"),
    @import("../webapi/collections/DOMRectList.zig"),
    @import("../webapi/DOMParser.zig"),
    @import("../webapi/XMLSerializer.zig"),
    @import("../webapi/XSLTProcessor.zig"),
    @import("../webapi/Sanitizer.zig"),
    @import("../webapi/AbstractRange.zig"),
    @import("../webapi/Range.zig"),
    @import("../webapi/StaticRange.zig"),
    @import("../webapi/NodeFilter.zig"),
    @import("../webapi/Element.zig"),
    @import("../webapi/element/DOMStringMap.zig"),
    @import("../webapi/element/CustomStateSet.zig"),
    @import("../webapi/element/ElementInternals.zig"),
    @import("../webapi/element/Attribute.zig"),
    @import("../webapi/element/Html.zig"),
    @import("../webapi/element/MathML.zig"),
    @import("../webapi/element/html/IFrame.zig"),
    @import("../webapi/element/html/Anchor.zig"),
    @import("../webapi/element/html/Area.zig"),
    @import("../webapi/element/html/Audio.zig"),
    @import("../webapi/element/html/Base.zig"),
    @import("../webapi/element/html/Body.zig"),
    @import("../webapi/element/html/BR.zig"),
    @import("../webapi/element/html/Button.zig"),
    @import("../webapi/element/html/Canvas.zig"),
    @import("../webapi/element/html/Custom.zig"),
    @import("../webapi/element/html/Data.zig"),
    @import("../webapi/element/html/DataList.zig"),
    @import("../webapi/element/html/Details.zig"),
    @import("../webapi/element/html/Dialog.zig"),
    @import("../webapi/element/html/Directory.zig"),
    @import("../webapi/element/html/Menu.zig"),
    @import("../webapi/element/html/FrameElement.zig"),
    @import("../webapi/element/html/DList.zig"),
    @import("../webapi/element/html/Div.zig"),
    @import("../webapi/element/html/Embed.zig"),
    @import("../webapi/element/html/FieldSet.zig"),
    @import("../webapi/element/html/Font.zig"),
    @import("../webapi/element/html/FrameSet.zig"),
    @import("../webapi/element/html/Form.zig"),
    @import("../webapi/element/html/Generic.zig"),
    @import("../webapi/element/html/Head.zig"),
    @import("../webapi/element/html/Heading.zig"),
    @import("../webapi/element/html/HR.zig"),
    @import("../webapi/element/html/Html.zig"),
    @import("../webapi/element/html/Image.zig"),
    @import("../webapi/element/html/Input.zig"),
    @import("../webapi/element/html/Label.zig"),
    @import("../webapi/element/html/Legend.zig"),
    @import("../webapi/element/html/LI.zig"),
    @import("../webapi/element/html/Link.zig"),
    @import("../webapi/element/html/Map.zig"),
    @import("../webapi/element/html/Marquee.zig"),
    @import("../webapi/element/html/Media.zig"),
    @import("../webapi/element/html/Meta.zig"),
    @import("../webapi/element/html/Meter.zig"),
    @import("../webapi/element/html/Mod.zig"),
    @import("../webapi/element/html/Object.zig"),
    @import("../webapi/element/html/OL.zig"),
    @import("../webapi/element/html/OptGroup.zig"),
    @import("../webapi/element/html/Option.zig"),
    @import("../webapi/element/html/Output.zig"),
    @import("../webapi/element/html/Paragraph.zig"),
    @import("../webapi/element/html/Picture.zig"),
    @import("../webapi/element/html/Param.zig"),
    @import("../webapi/element/html/Pre.zig"),
    @import("../webapi/element/html/Progress.zig"),
    @import("../webapi/element/html/Quote.zig"),
    @import("../webapi/element/html/Script.zig"),
    @import("../webapi/element/html/Select.zig"),
    @import("../webapi/element/html/SelectedContent.zig"),
    @import("../webapi/element/html/Slot.zig"),
    @import("../webapi/element/html/Geolocation.zig"),
    @import("../webapi/element/html/UserMedia.zig"),
    @import("../webapi/element/html/Source.zig"),
    @import("../webapi/element/html/Span.zig"),
    @import("../webapi/element/html/Style.zig"),
    @import("../webapi/element/html/Table.zig"),
    @import("../webapi/element/html/TableCaption.zig"),
    @import("../webapi/element/html/TableCell.zig"),
    @import("../webapi/element/html/TableCol.zig"),
    @import("../webapi/element/html/TableRow.zig"),
    @import("../webapi/element/html/TableSection.zig"),
    @import("../webapi/element/html/Template.zig"),
    @import("../webapi/element/html/TextArea.zig"),
    @import("../webapi/element/html/Time.zig"),
    @import("../webapi/element/html/Title.zig"),
    @import("../webapi/element/html/Track.zig"),
    @import("../webapi/element/html/Video.zig"),
    @import("../webapi/element/html/UL.zig"),
    @import("../webapi/element/html/Unknown.zig"),
    @import("../webapi/element/html/ValidityState.zig"),
    @import("../webapi/element/Svg.zig"),
    @import("../webapi/element/svg/Generic.zig"),
    @import("../webapi/element/svg/Graphics.zig"),
    @import("../webapi/element/svg/Geometry.zig"),
    @import("../webapi/element/svg/Svg.zig"),
    @import("../webapi/element/svg/G.zig"),
    @import("../webapi/element/svg/A.zig"),
    @import("../webapi/element/svg/Use.zig"),
    @import("../webapi/element/svg/Image.zig"),
    @import("../webapi/element/svg/Defs.zig"),
    @import("../webapi/element/svg/Symbol.zig"),
    @import("../webapi/element/svg/Switch.zig"),
    @import("../webapi/element/svg/ForeignObject.zig"),
    @import("../webapi/element/svg/TextContent.zig"),
    @import("../webapi/element/svg/TextPositioning.zig"),
    @import("../webapi/element/svg/Text.zig"),
    @import("../webapi/element/svg/TSpan.zig"),
    @import("../webapi/element/svg/TextPath.zig"),
    @import("../webapi/element/svg/View.zig"),
    @import("../webapi/element/svg/Title.zig"),
    @import("../webapi/element/svg/Desc.zig"),
    @import("../webapi/element/svg/Metadata.zig"),
    @import("../webapi/element/svg/GradientElement.zig"),
    @import("../webapi/element/svg/LinearGradient.zig"),
    @import("../webapi/element/svg/RadialGradient.zig"),
    @import("../webapi/element/svg/ClipPath.zig"),
    @import("../webapi/element/svg/Marker.zig"),
    @import("../webapi/element/svg/Mask.zig"),
    @import("../webapi/element/svg/Pattern.zig"),
    @import("../webapi/element/svg/Stop.zig"),
    @import("../webapi/element/svg/Rect.zig"),
    @import("../webapi/element/svg/Circle.zig"),
    @import("../webapi/element/svg/Ellipse.zig"),
    @import("../webapi/element/svg/Line.zig"),
    @import("../webapi/element/svg/Path.zig"),
    @import("../webapi/element/svg/Polygon.zig"),
    @import("../webapi/element/svg/Polyline.zig"),
    @import("../webapi/element/svg/filter.zig"),
    @import("../webapi/element/svg/animation.zig"),
    @import("../webapi/element/svg/Script.zig"),
    @import("../webapi/element/svg/Style.zig"),
    @import("../webapi/svg/UnitTypes.zig"),
    @import("../webapi/svg/NumberList.zig"),
    @import("../webapi/svg/AnimatedNumberList.zig"),
    @import("../webapi/svg/LengthList.zig"),
    @import("../webapi/svg/AnimatedLengthList.zig"),
    @import("../webapi/svg/AnimatedRect.zig"),
    @import("../webapi/svg/AnimatedAngle.zig"),
    @import("../webapi/svg/AnimatedInteger.zig"),
    @import("../webapi/svg/AnimatedBoolean.zig"),
    @import("../webapi/svg/AnimatedString.zig"),
    @import("../webapi/svg/Number.zig"),
    @import("../webapi/svg/Rect.zig"),
    @import("../webapi/svg/Point.zig"),
    @import("../webapi/svg/Matrix.zig"),
    @import("../webapi/svg/Length.zig"),
    @import("../webapi/svg/Angle.zig"),
    @import("../webapi/svg/Transform.zig"),
    @import("../webapi/svg/AnimatedLength.zig"),
    @import("../webapi/svg/AnimatedNumber.zig"),
    @import("../webapi/svg/AnimatedEnumeration.zig"),
    @import("../webapi/svg/PreserveAspectRatio.zig"),
    @import("../webapi/svg/AnimatedPreserveAspectRatio.zig"),
    @import("../webapi/svg/PointList.zig"),
    @import("../webapi/svg/TransformList.zig"),
    @import("../webapi/svg/AnimatedTransformList.zig"),
    @import("../webapi/svg/StringList.zig"),
    @import("../webapi/encoding/TextDecoder.zig"),
    @import("../webapi/encoding/TextEncoder.zig"),
    @import("../webapi/encoding/TextEncoderStream.zig"),
    @import("../webapi/encoding/TextDecoderStream.zig"),
    @import("../webapi/Event.zig"),
    @import("../webapi/event/CompositionEvent.zig"),
    @import("../webapi/event/CustomEvent.zig"),
    @import("../webapi/event/ErrorEvent.zig"),
    @import("../webapi/event/MessageEvent.zig"),
    @import("../webapi/event/ProgressEvent.zig"),
    @import("../webapi/event/NavigationCurrentEntryChangeEvent.zig"),
    @import("../webapi/event/PageTransitionEvent.zig"),
    @import("../webapi/event/PopStateEvent.zig"),
    @import("../webapi/event/HashChangeEvent.zig"),
    @import("../webapi/event/BeforeUnloadEvent.zig"),
    @import("../webapi/event/StorageEvent.zig"),
    @import("../webapi/event/DeviceMotionEvent.zig"),
    @import("../webapi/event/GamepadEvent.zig"),
    @import("../webapi/event/DeviceOrientationEvent.zig"),
    @import("../webapi/event/TouchEvent.zig"),
    @import("../webapi/event/touch.zig"),
    @import("../webapi/event/misc_events.zig"),
    @import("../webapi/event/surface_events.zig"),
    @import("../webapi/event/UIEvent.zig"),
    @import("../webapi/event/MouseEvent.zig"),
    @import("../webapi/event/PointerEvent.zig"),
    @import("../webapi/event/KeyboardEvent.zig"),
    @import("../webapi/event/FocusEvent.zig"),
    @import("../webapi/event/WheelEvent.zig"),
    @import("../webapi/event/DragEvent.zig"),
    @import("../webapi/event/TextEvent.zig"),
    @import("../webapi/event/InputEvent.zig"),
    @import("../webapi/event/PromiseRejectionEvent.zig"),
    @import("../webapi/event/SubmitEvent.zig"),
    @import("../webapi/event/FormDataEvent.zig"),
    @import("../webapi/event/ToggleEvent.zig"),
    @import("../webapi/event/css_events.zig"),
    @import("../webapi/animation/effects.zig"),
    @import("../webapi/MessageChannel.zig"),
    @import("../webapi/MessagePort.zig"),
    @import("../webapi/BroadcastChannel.zig"),
    @import("../webapi/Worker.zig"),
    @import("../webapi/SharedWorker.zig"),
    @import("../webapi/media/MediaError.zig"),
    @import("../webapi/media/TextTrackCue.zig"),
    @import("../webapi/media/TimeRanges.zig"),
    @import("../webapi/media/text_tracks.zig"),
    @import("../webapi/media/capture.zig"),
    @import("../webapi/media/PictureInPictureWindow.zig"),
    @import("../webapi/media/VTTCue.zig"),
    @import("../webapi/animation/Animation.zig"),
    @import("../webapi/document/services.zig"),
    @import("../webapi/animation/timelines.zig"),
    @import("../webapi/EventTarget.zig"),
    @import("../webapi/Location.zig"),
    @import("../webapi/ModelContext.zig"),
    @import("../webapi/Navigator.zig"),
    @import("../webapi/NavigatorUAData.zig"),
    @import("../webapi/Notification.zig"),
    @import("../webapi/net/FormData.zig"),
    @import("../webapi/net/Headers.zig"),
    @import("../webapi/net/Request.zig"),
    @import("../webapi/net/Response.zig"),
    @import("../webapi/net/URLSearchParams.zig"),
    @import("../webapi/net/XMLHttpRequest.zig"),
    @import("../webapi/net/XMLHttpRequestEventTarget.zig"),
    @import("../webapi/net/XMLHttpRequestUpload.zig"),
    @import("../webapi/net/WebSocket.zig"),
    @import("../webapi/net/EventSource.zig"),
    @import("../webapi/event/CloseEvent.zig"),
    @import("../webapi/streams/ReadableStream.zig"),
    @import("../webapi/streams/ReadableStreamDefaultReader.zig"),
    @import("../webapi/streams/ReadableStreamDefaultController.zig"),
    @import("../webapi/streams/WritableStream.zig"),
    @import("../webapi/streams/WritableStreamDefaultWriter.zig"),
    @import("../webapi/streams/WritableStreamDefaultController.zig"),
    @import("../webapi/streams/TransformStream.zig"),
    @import("../webapi/streams/queuing_strategy.zig"),
    @import("../webapi/streams/byte_stream.zig"),
    @import("../webapi/streams/compression.zig"),
    @import("../webapi/Node.zig"),
    @import("../webapi/storage/storage.zig"),
    @import("../webapi/storage/CookieStore.zig"),
    @import("../webapi/storage/idb/idb.zig"),
    @import("../webapi/event/CookieChangeEvent.zig"),
    @import("../webapi/URL.zig"),
    @import("../webapi/URLPattern.zig"),
    @import("../webapi/Origin.zig"),
    @import("../webapi/Window.zig"),
    @import("../webapi/Performance.zig"),
    @import("../webapi/performance/timing.zig"),
    @import("../webapi/EventCounts.zig"),
    @import("../webapi/PluginArray.zig"),
    @import("../webapi/NetworkInformation.zig"),
    @import("../webapi/media/MediaDevices.zig"),
    // Media type support: CreepJS reads canPlayType, MediaSource.isTypeSupported
    // and MediaRecorder.isTypeSupported as one grid, so all three exist.
    @import("../webapi/media/MediaSource.zig"),
    @import("../webapi/media/streams.zig"),
    @import("../webapi/media/MediaRecorder.zig"),
    @import("../webapi/media/eme.zig"),
    @import("../webapi/media/MediaMetadata.zig"),
    @import("../webapi/media/breakout_box.zig"),
    @import("../webapi/media/image_capture.zig"),
    @import("../webapi/media/playback.zig"),
    @import("../webapi/BatteryManager.zig"),
    @import("../webapi/navigator/services.zig"),
    @import("../webapi/navigator/devices.zig"),
    @import("../webapi/MutationObserver.zig"),
    @import("../webapi/IntersectionObserver.zig"),
    @import("../webapi/CustomElementRegistry.zig"),
    @import("../webapi/ResizeObserver.zig"),
    @import("../webapi/IdleDeadline.zig"),
    @import("../webapi/Blob.zig"),
    @import("../webapi/File.zig"),
    @import("../webapi/FileList.zig"),
    @import("../webapi/FileReader.zig"),
    @import("../webapi/DataTransfer.zig"),
    @import("../webapi/Screen.zig"),
    @import("../webapi/scheduler.zig"),
    @import("../webapi/VisualViewport.zig"),
    @import("../webapi/Viewport.zig"),
    @import("../webapi/BarProp.zig"),
    @import("../webapi/trusted_types.zig"),
    @import("../webapi/screen_details.zig"),
    @import("../webapi/file_system_access.zig"),
    @import("../webapi/FontData.zig"),
    @import("../webapi/launch_queue.zig"),
    @import("../webapi/canvas/ImageBitmap.zig"),
    @import("../webapi/canvas/ImageBitmapRenderingContext.zig"),
    @import("../webapi/storage/cache_storage.zig"),
    @import("../webapi/sensor.zig"),
    @import("../webapi/midi.zig"),
    @import("../webapi/navigator/bluetooth.zig"),
    @import("../webapi/navigator/usb.zig"),
    @import("../webapi/navigator/hid_serial.zig"),
    @import("../webapi/navigator/credentials.zig"),
    @import("../webapi/presentation.zig"),
    @import("../webapi/payment.zig"),
    @import("../webapi/gamepad.zig"),
    @import("../webapi/geolocation.zig"),
    @import("../webapi/service_worker.zig"),
    @import("../webapi/web_transport.zig"),
    @import("../webapi/External.zig"),
    @import("../webapi/StyleMedia.zig"),
    @import("../webapi/PerformanceObserver.zig"),
    @import("../webapi/ReportingObserver.zig"),
    @import("../webapi/reporting.zig"),
    @import("../webapi/navigation/Navigation.zig"),
    @import("../webapi/navigation/NavigationHistoryEntry.zig"),
    @import("../webapi/navigation/NavigationActivation.zig"),
    @import("../webapi/navigation/NavigationDestination.zig"),
    @import("../webapi/navigation/NavigationTransition.zig"),
    @import("../webapi/navigation/NavigationPrecommitController.zig"),
    @import("../webapi/canvas/CanvasRenderingContext2D.zig"),
    @import("../webapi/canvas/WebGLRenderingContext.zig"),
    @import("../webapi/canvas/WebGL2RenderingContext.zig"),
    @import("../webapi/canvas/webgl_objects.zig"),
    @import("../webapi/canvas/OffscreenCanvas.zig"),
    @import("../webapi/canvas/OffscreenCanvasRenderingContext2D.zig"),
    @import("../webapi/canvas/Path2D.zig"),
    @import("../webapi/canvas/TextMetrics.zig"),
    @import("../webapi/canvas/canvas_objects.zig"),
    @import("../webapi/SubtleCrypto.zig"),
    @import("../webapi/CryptoKey.zig"),
    @import("../webapi/Selection.zig"),
    @import("../webapi/ImageData.zig"),
    @import("../webapi/XPathResult.zig"),
    @import("../webapi/XPathExpression.zig"),
    @import("../webapi/XPathEvaluator.zig"),
    @import("../webapi/collections/DOMStringList.zig"),
    // Web Audio: window-only in Chrome (no AudioContext in workers).
    @import("../webapi/audio/BaseAudioContext.zig"),
    @import("../webapi/audio/AudioContext.zig"),
    @import("../webapi/audio/OfflineAudioContext.zig"),
    @import("../webapi/audio/AudioNode.zig"),
    @import("../webapi/audio/AudioDestinationNode.zig"),
    @import("../webapi/audio/AnalyserNode.zig"),
    @import("../webapi/audio/AudioListener.zig"),
    @import("../webapi/audio/AudioParam.zig"),
    @import("../webapi/audio/AudioBuffer.zig"),
    @import("../webapi/audio/PeriodicWave.zig"),
    @import("../webapi/audio/AudioScheduledSourceNode.zig"),
    @import("../webapi/audio/nodes.zig"),
    @import("../webapi/audio/worklet.zig"),
    @import("../webapi/audio/media_nodes.zig"),
    @import("../webapi/audio/events.zig"),
    // Web Speech synthesis: window-only in Chrome, like the audio types
    // (measured: typeof self.speechSynthesis === 'undefined' in a worker).
    @import("../webapi/speech/SpeechSynthesis.zig"),
    @import("../webapi/speech/SpeechSynthesisUtterance.zig"),
    @import("../webapi/speech/SpeechSynthesisVoice.zig"),
    @import("../webapi/speech/SpeechSynthesisEvent.zig"),
    @import("../webapi/speech/SpeechSynthesisErrorEvent.zig"),
    // Web Speech recognition: window-only for the same reason, and the five
    // webkit-prefixed spellings are the names CreepJS counts.
    @import("../webapi/speech/recognition.zig"),
    // The sandboxed filesystem: window-only, and none of its interfaces is a
    // global (see filesystem.zig).
    @import("../webapi/filesystem.zig"),
    // WebRTC: window-only in Chrome. A worker global carries RTCDataChannel and
    // the encoded-frame types but no RTCPeerConnection (measured: the RTC* keys
    // on a DedicatedWorkerGlobalScope are RTCTransformEvent,
    // RTCRtpScriptTransformer, RTCDataChannel, RTCEncodedVideoFrame,
    // RTCEncodedAudioFrame), and none of those are reachable without a
    // connection to hand them out.
    @import("../webapi/webrtc/RTCPeerConnection.zig"),
    @import("../webapi/webrtc/RTCSessionDescription.zig"),
    @import("../webapi/webrtc/RTCIceCandidate.zig"),
    @import("../webapi/webrtc/RTCDataChannel.zig"),
    @import("../webapi/webrtc/RTCPeerConnectionIceEvent.zig"),
    @import("../webapi/webrtc/RTCStatsReport.zig"),
    @import("../webapi/webrtc/rtp.zig"),
    @import("../webapi/webrtc/transports.zig"),
    @import("../webapi/webrtc/RTCCertificate.zig"),
    @import("../webapi/webrtc/RTCError.zig"),
    @import("../webapi/webrtc/events.zig"),
    @import("../webapi/webrtc/encoded_frames.zig"),
    @import("../webapi/webrtc/RTCRtpScriptTransform.zig"),

    @import("../webapi/webgpu/constants.zig"),
    @import("../webapi/webgpu/adapter.zig"),
    @import("../webapi/webgpu/device.zig"),
    @import("../webapi/webgpu/resources.zig"),
    @import("../webapi/webgpu/pipeline.zig"),
    @import("../webapi/webgpu/errors.zig"),

    @import("../webapi/webcodecs/frames.zig"),
    @import("../webapi/webcodecs/chunks.zig"),
    @import("../webapi/webcodecs/codecs.zig"),
    @import("../webapi/webcodecs/image_decoder.zig"),

    @import("../webapi/webxr/geometry.zig"),
    @import("../webapi/webxr/spaces.zig"),
    @import("../webapi/webxr/input.zig"),
    @import("../webapi/webxr/features.zig"),
    @import("../webapi/webxr/layers.zig"),
    @import("../webapi/webxr/session.zig"),
});

// APIs available on every Worker context global (constructors like URL,
// Headers, etc.), regardless of worker kind. Each kind's snapshot context
// adds its own global-scope type on top (DedicatedWorkerJsApis,
// SharedWorkerJsApis below).
// This is a subset of PageJsApis plus WorkerGlobalScope.
// TODO: Expand this list to include all worker-appropriate APIs.
const worker_common_apis = [_]type{
    @import("../webapi/WorkerGlobalScope.zig"),
    @import("../webapi/WorkerLocation.zig"),
    // A worker's navigator is a WorkerNavigator, and Chrome has no `Navigator`
    // interface object in this realm at all (measured,
    // probes/expr-worker-surface.js).
    @import("../webapi/WorkerNavigator.zig"),
    @import("../webapi/NavigatorUAData.zig"),
    @import("../webapi/Permissions.zig"),
    @import("../webapi/StorageManager.zig"),
    @import("../webapi/EventTarget.zig"),
    @import("../webapi/Event.zig"),
    @import("../webapi/event/MessageEvent.zig"),
    @import("../webapi/event/ErrorEvent.zig"),
    @import("../webapi/event/PromiseRejectionEvent.zig"),
    @import("../webapi/event/CloseEvent.zig"),
    @import("../webapi/DOMException.zig"),
    @import("../webapi/QuotaExceededError.zig"),
    @import("../webapi/DOMRectReadOnly.zig"),
    @import("../webapi/DOMRect.zig"),
    @import("../webapi/DOMMatrixReadOnly.zig"),
    @import("../webapi/DOMMatrix.zig"),
    @import("../webapi/DOMPointReadOnly.zig"),
    @import("../webapi/DOMPoint.zig"),
    @import("../webapi/DOMQuad.zig"),
    @import("../webapi/net/URLSearchParams.zig"),
    @import("../webapi/encoding/TextEncoder.zig"),
    @import("../webapi/encoding/TextDecoder.zig"),
    @import("../webapi/Blob.zig"),
    @import("../webapi/File.zig"),
    @import("../webapi/Console.zig"),
    @import("../webapi/Crypto.zig"),
    @import("../webapi/SubtleCrypto.zig"),
    @import("../webapi/CryptoKey.zig"),
    @import("../webapi/net/FormData.zig"),
    @import("../webapi/net/Headers.zig"),
    @import("../webapi/net/Request.zig"),
    @import("../webapi/net/Response.zig"),
    @import("../webapi/streams/TransformStream.zig"),
    @import("../webapi/streams/queuing_strategy.zig"),
    @import("../webapi/streams/byte_stream.zig"),
    @import("../webapi/streams/compression.zig"),
    @import("../webapi/streams/ReadableStream.zig"),
    @import("../webapi/streams/ReadableStreamDefaultReader.zig"),
    @import("../webapi/streams/ReadableStreamDefaultController.zig"),
    @import("../webapi/streams/WritableStream.zig"),
    @import("../webapi/streams/WritableStreamDefaultWriter.zig"),
    @import("../webapi/streams/WritableStreamDefaultController.zig"),
    @import("../webapi/web_transport.zig"),
    @import("../webapi/encoding/TextEncoderStream.zig"),
    @import("../webapi/encoding/TextDecoderStream.zig"),
    @import("../webapi/AbortSignal.zig"),
    @import("../webapi/AbortController.zig"),
    @import("../webapi/URL.zig"),
    @import("../webapi/URLPattern.zig"),
    @import("../webapi/canvas/OffscreenCanvas.zig"),
    @import("../webapi/canvas/OffscreenCanvasRenderingContext2D.zig"),
    // An OffscreenCanvas hands back a WebGL context inside a worker too, so
    // both interfaces and their object handles are Exposed=(Window,Worker) in
    // Chrome (measured: typeof self.WebGLRenderingContext === 'function').
    @import("../webapi/canvas/WebGLRenderingContext.zig"),
    @import("../webapi/canvas/WebGL2RenderingContext.zig"),
    @import("../webapi/canvas/webgl_objects.zig"),
    @import("../webapi/canvas/Path2D.zig"),
    @import("../webapi/canvas/TextMetrics.zig"),
    @import("../webapi/canvas/canvas_objects.zig"),
    @import("../webapi/net/XMLHttpRequest.zig"),
    @import("../webapi/net/XMLHttpRequestEventTarget.zig"),
    @import("../webapi/net/XMLHttpRequestUpload.zig"),
    @import("../webapi/net/WebSocket.zig"),
    @import("../webapi/net/EventSource.zig"),
    @import("../webapi/FileReader.zig"),
    @import("../webapi/FileReaderSync.zig"),
    @import("../webapi/ImageData.zig"),
    @import("../webapi/Performance.zig"),
    @import("../webapi/PerformanceObserver.zig"),
    @import("../webapi/ReportingObserver.zig"),
    // The one name of the reporting family a Chrome worker carries (measured,
    // probe-shapes-worker); the two bodies under it and the bfcache objects are
    // window-only.
    @import("../webapi/reporting.zig").ReportBody,
    // The other two of the 47 surface names a Chrome worker carries: everything
    // else in that cut is window-only (measured, probe-shapes-worker).
    @import("../webapi/Origin.zig"),
    @import("../webapi/canvas/webgl_objects.zig").WebGLObject,
    // CookieStore and CookieChangeEvent are Window and ServiceWorker; a
    // dedicated worker carries neither (measured).
    @import("../webapi/storage/idb/idb.zig"),
    @import("../webapi/BroadcastChannel.zig"),
    @import("../webapi/event/CustomEvent.zig"),
    @import("../webapi/event/ProgressEvent.zig"),
    // The only two of the misc Event subclasses a Chrome worker carries
    // (measured, probe-win30 `worker`).
    @import("../webapi/event/misc_events.zig").SecurityPolicyViolationEvent,
    @import("../webapi/event/misc_events.zig").WebGLContextEvent,
    // CropTarget is on a worker too (measured); the rest of the capture family
    // is window-only.
    @import("../webapi/media/capture.zig").CropTarget,
    @import("../webapi/Notification.zig"),
    @import("../webapi/FileList.zig"),
    @import("../webapi/MessageChannel.zig"),
    @import("../webapi/MessagePort.zig"),
    @import("../webapi/collections/DOMStringList.zig"),
    // The File System Access handles are Exposed=(Window,Worker): a worker is
    // where OPFS is actually usable, since createSyncAccessHandle only exists
    // there. FileSystemSyncAccessHandle itself is Exposed=DedicatedWorker, so it
    // is named in DedicatedWorkerJsApis alone rather than here.
    @import("../webapi/file_system_access.zig"),

    // Everything below closes part of the shortfall this list's old
    // "TODO: Expand" carried: interfaces this engine already implements for the
    // page realm and a Chrome worker also carries (measured against
    // results/probes/expr-worker-surface.chrome.json).
    //
    // The cut is drawn by a hard constraint rather than by taste: not one
    // member of any of these types takes a `*Frame`. A worker realm cannot be
    // handed its owner's Frame -- see the comment on getGlobalArg in Caller.zig,
    // which is a live SIGABRT on the Cloudflare station and not a style
    // preference -- so the Frame-taking families stay out even though Chrome's
    // worker has them: the typed-OM transform components and nested Worker.
    // Trusted Types, WebGPU, MSE, the storage buckets, the font families and the
    // sandboxed filesystem were all on that list until their members were
    // converted to take an `*Execution`. The question to ask of a `*Frame` is
    // never "can a worker have one" -- it cannot -- but "what is this member
    // reaching through it for": a factory, an arena, the isolate, a local
    // handle, a listener list and a global's own slots are all per-realm and all
    // reachable from the Execution, and only a member that wants the DOM, the
    // frame's navigation state or its loader is really blocked.
    //
    // What that audit left out, and why:
    //
    // - `Worker` (nested workers). Genuinely frame-scoped: `Worker.init` takes
    //   the session off the frame, resolves against the frame's base URL, calls
    //   `frame.newRequest` to fetch the script and `frame.trackWorker` to
    //   register it. Spawning from a worker needs a worker-side spawn path, not
    //   an argument change.
    // - `CSSSkewX`/`CSSSkewY`. Convertible in principle -- typed_om.zig's 112
    //   `frame: *Frame` signatures want `js`, `local_arena`, `_factory`,
    //   `dupeString`, `arena`, `call_arena` and `_page`, every one of which is
    //   on the Execution -- but Chrome exposes exactly these two of the whole
    //   typed-OM family in a worker and none of their prototype chain
    //   (CSSTransformComponent, CSSStyleValue), so matching it is not just a
    //   mechanical conversion of the largest file in the audit.
    //
    // WebCodecs, the RTC worker surface, MSE, IdleDetector and the device
    // families all used to sit here. They are Exposed=DedicatedWorker, not
    // Exposed=Worker: a Chrome SharedWorker carries none of the 41 interface
    // objects they bring (measured, probes/expr-shared-worker-proto-table.js).
    // See dedicated_worker_only_apis below.
    // The font families. `FontFaceSet.load` dispatches two events, and the
    // listener list it dispatched into was the frame's -- through
    // `GlobalScope.eventManagerBase()` it is this realm's, which is what an
    // EventTarget exposed in two realms needs. FontFaceSetLoadEvent is
    // Window-only and lives in event/css_events.zig, so it does not travel.
    @import("../webapi/css/FontFace.zig"),
    @import("../webapi/css/FontFaceSet.zig"),
    // An ImageBitmap is the transferable image handle a worker decodes into,
    // and its canvas context comes along with it.
    @import("../webapi/canvas/ImageBitmap.zig"),
    @import("../webapi/canvas/ImageBitmapRenderingContext.zig"),
    // The prioritised-task scheduler. `self.scheduler` was already here; the
    // interface objects behind it were not.
    @import("../webapi/scheduler.zig"),
    @import("../webapi/storage/cache_storage.zig"),
    @import("../webapi/NetworkInformation.zig"),
    // Resource and server timing are the two Performance entry types a worker
    // gets; the rest of the timing family is window-only (measured). Their
    // shared PerformanceEntry prototype is already in this realm.
    @import("../webapi/performance/timing.zig").ResourceTiming,
    @import("../webapi/performance/timing.zig").ServerTiming,
    // The service-worker client surface, minus the two of service_worker.zig's
    // twelve that a dedicated worker does not carry: ServiceWorker itself and
    // CookieStoreManager (the cookie store is Window and ServiceWorker only,
    // which is why CookieStore is absent from this realm too).
    @import("../webapi/service_worker.zig").ServiceWorkerRegistration,
    @import("../webapi/service_worker.zig").PushManager,
    @import("../webapi/service_worker.zig").PushSubscription,
    @import("../webapi/service_worker.zig").PushSubscriptionOptions,
    @import("../webapi/service_worker.zig").BackgroundFetchManager,
    @import("../webapi/service_worker.zig").BackgroundFetchRecord,
    @import("../webapi/service_worker.zig").BackgroundFetchRegistration,
    @import("../webapi/service_worker.zig").SyncManager,
    @import("../webapi/service_worker.zig").PeriodicSyncManager,
    @import("../webapi/service_worker.zig").NavigationPreloadManager,
    // Eight of navigator/services.zig's seventeen. The other nine the file
    // registers are window-only, which is the only reason it is still named
    // type by type rather than imported whole.
    @import("../webapi/navigator/services.zig").Lock,
    @import("../webapi/navigator/services.zig").LockManager,
    @import("../webapi/navigator/services.zig").MediaCapabilities,
    @import("../webapi/navigator/services.zig").UserActivation,
    // The bucket family. `StorageBucket.indexedDB` used to reach
    // `exec.js.global.frame.window` -- past the union, on the stated assumption
    // that the global is always a Frame. Both arms of that union answer
    // `getIndexedDB`, so switching on it is the whole fix, and a bucket in a
    // worker now shares the worker's factory rather than the owner window's.
    @import("../webapi/navigator/services.zig").StorageBucket,
    @import("../webapi/navigator/services.zig").StorageBucketManager,
    // `GPU` was the seventh reason this file could not travel whole: its
    // `wgslLanguageFeatures` took a `*Frame`. It wanted the Frame's `_factory`
    // and nothing else, and every Execution carries one, so the accessor takes
    // an `*Execution` now and the whole WebGPU family comes with it. A worker is
    // where a page does its GPU compute, and Chrome exposes all 40 interface
    // objects plus `navigator.gpu` here (measured).
    @import("../webapi/navigator/services.zig").GPU,
    @import("../webapi/navigator/services.zig").WGSLLanguageFeatures,
    @import("../webapi/navigator/services.zig").WGSLLanguageFeatures.KeyIterator,
    @import("../webapi/navigator/services.zig").WGSLLanguageFeatures.ValueIterator,
    @import("../webapi/navigator/services.zig").WGSLLanguageFeatures.EntryIterator,
    @import("../webapi/webgpu/constants.zig"),
    @import("../webapi/webgpu/adapter.zig"),
    @import("../webapi/webgpu/device.zig"),
    @import("../webapi/webgpu/resources.zig"),
    @import("../webapi/webgpu/pipeline.zig"),
    @import("../webapi/webgpu/errors.zig"),
    // Trusted Types, which used to be the ceiling: every member of the factory
    // took a `*Frame`, and a worker cannot be handed one. They take an
    // `*Execution` now, which Env.zig builds per context out of that context's
    // own global -- so the factory a worker creates in is the worker's. The
    // station's trampoline worker opens with `if (self.trustedTypes)`.
    @import("../webapi/trusted_types.zig"),
};

// Exposed=DedicatedWorker, not Exposed=Worker. Measured by running the same
// interface-table probe in a dedicated worker and in a shared worker on Chrome
// 151 (probes/expr-worker-proto-table.js and
// probes/expr-shared-worker-proto-table.js): the dedicated realm carries all of
// these and the shared realm carries none of them -- 41 interface objects that
// were on this engine's SharedWorker global and are not on Chrome's.
//
// That is not a hypothetical surface. The Akamai interstitial on macys.com
// runs its sensor from a SharedWorker, so every name here was one an
// `Object.getOwnPropertyNames(self)` in that realm could read off us and not
// off a browser.
const dedicated_worker_only_apis = [_]type{
    // Chrome's dedicated worker scope carries IdleDetector (measured,
    // probe-win30).
    @import("../webapi/IdleDetector.zig"),
    // The RTC surface a Chrome DedicatedWorkerGlobalScope carries, measured:
    // exactly RTCTransformEvent, RTCRtpScriptTransformer, RTCDataChannel,
    // RTCEncodedVideoFrame and RTCEncodedAudioFrame — no RTCPeerConnection.
    @import("../webapi/webrtc/encoded_frames.zig"),
    @import("../webapi/webrtc/RTCDataChannel.zig"),
    @import("../webapi/webrtc/worker_transform.zig"),
    // WebCodecs: the encode/decode pipeline is the reason a page moves media
    // work into a dedicated worker at all.
    @import("../webapi/webcodecs/chunks.zig"),
    @import("../webapi/webcodecs/codecs.zig"),
    @import("../webapi/webcodecs/frames.zig"),
    @import("../webapi/webcodecs/image_decoder.zig"),
    // MSE-in-Worker. A dedicated worker is the only realm Chrome lets a
    // MediaSource be constructed in at all -- `canConstructInDedicatedWorker`
    // is a static that exists to say so. Its two list accessors reach the
    // factory through the Execution, so the SourceBufferList is branded in
    // this realm rather than the owner's.
    @import("../webapi/media/MediaSource.zig"),
    // The device families, whole: a Chrome dedicated worker carries every USB,
    // HID and Serial interface object even though the WorkerNavigator members
    // that hand them out are window-only.
    @import("../webapi/navigator/usb.zig"),
    @import("../webapi/navigator/hid_serial.zig"),
    // Only the three device entry points out of devices.zig. The other ten it
    // registers -- Bluetooth, Clipboard, ServiceWorkerContainer, XRSystem and
    // friends -- are window-only.
    @import("../webapi/navigator/devices.zig").HID,
    @import("../webapi/navigator/devices.zig").Serial,
    @import("../webapi/navigator/devices.zig").USB,
};

pub const DedicatedWorkerJsApis = flattenTypes(&([_]type{
    @import("../webapi/DedicatedWorkerGlobalScope.zig"),
    // [Exposed=DedicatedWorker]: a shared worker does not carry it.
    @import("../webapi/file_system_access.zig").FileSystemSyncAccessHandle,
} ++ dedicated_worker_only_apis ++ worker_common_apis));
pub const SharedWorkerJsApis = flattenTypes(&([_]type{@import("../webapi/SharedWorkerGlobalScope.zig")} ++ worker_common_apis));

// Master list of ALL JS APIs across all contexts.
// Used by Env (class IDs, templates), JsApiLookup, and anywhere that needs
// to know about all possible types. Individual snapshots use their own
// subsets (PageJsApis, WorkerSnapshot.JsApis).
pub const JsApis = blk: {
    // worker_transform's interfaces are [Exposed=Worker]-only, so they are
    // named here rather than reached through PageJsApis.
    const base = PageJsApis ++ flattenTypes(&.{@import("../webapi/webrtc/worker_transform.zig")}) ++ [_]type{
        // Worker-only, so it isn't in PageJsApis either.
        @import("../webapi/FileReaderSync.zig").JsApi,
        @import("../webapi/file_system_access.zig").FileSystemSyncAccessHandle.JsApi,
        @import("../webapi/DedicatedWorkerGlobalScope.zig").JsApi,
        @import("../webapi/SharedWorkerGlobalScope.zig").JsApi,
        @import("../webapi/WorkerGlobalScope.zig").JsApi,
        @import("../webapi/WorkerLocation.zig").JsApi,
        @import("../webapi/WorkerNavigator.zig").JsApi,
    };
    if (lp.build_config.wpt_extensions == false) {
        break :blk base;
    }
    break :blk base ++ [_]type{@import("../webapi/WebDriver.zig").JsApi};
};

// Whether Child is Ancestor or inherits from it, following the Proto chain.
pub fn inheritsOrIs(comptime Child: type, comptime Ancestor: type) bool {
    comptime {
        const target = Ancestor.bridge.type;
        var T = Child.bridge.type;
        while (true) {
            if (T == target) {
                return true;
            }
            T = reflect.Proto(T) orelse return false;
        }
    }
}

const testing = @import("../../testing.zig");
// Not "does the property answer the right value" -- every other test does that
// -- but "is it the right *kind* of property", which is what this file decides
// and what a bot check reads through
// `Object.getOwnPropertyDescriptor(P, k).get.call(o)`.
test "WebApi: descriptor kind" {
    try testing.htmlRunner("descriptor_kind.html", .{});
}

// How a dictionary is read out of a JS object: one [[Get]] per member and an
// `undefined` treated as absent, which is what a Proxy handed to a constructor
// sees -- and Kasada's payload carries exactly that log.
test "WebApi: webidl dictionary conversion" {
    try testing.htmlRunner("webidl_dictionary.html", .{});
}

// The read log's answer to "431 calls to matchMedia asking what?". Only the
// key-building half is testable without a page; that a call reaches it at all
// is what the prop_arg scope on a real run shows.
test "bridge: property read argument key" {
    var buf: [256]u8 = undefined;

    // No argument, or one we don't key on: the member alone, byte-identical to
    // what the plain read log emits, so the two runs stay comparable.
    try testing.expectEqual("Window.matchMedia", formatArgumentKey(&buf, "Window.matchMedia", null));

    try testing.expectEqual(
        "Window.matchMedia(\"(min-width: 100px)\")",
        formatArgumentKey(&buf, "Window.matchMedia", .{ .string = "(min-width: 100px)" }),
    );
    try testing.expectEqual(
        "HTMLMediaElement.canPlayType(\"video/mp4; codecs=\"avc1.42E01E\"\")",
        formatArgumentKey(&buf, "HTMLMediaElement.canPlayType", .{ .string = "video/mp4; codecs=\"avc1.42E01E\"" }),
    );

    // A WebGL enum has to read as the integer the page passed; 3.7446e4 would
    // not match anything in the registry.
    try testing.expectEqual(
        "WebGLRenderingContext.getParameter(37446)",
        formatArgumentKey(&buf, "WebGLRenderingContext.getParameter", .{ .number = 37446 }),
    );
    try testing.expectEqual(
        "CanvasRenderingContext2D.rotate(-0.5)",
        formatArgumentKey(&buf, "CanvasRenderingContext2D.rotate", .{ .number = -0.5 }),
    );

    // A control byte in the value would send the whole logfmt line through
    // base64, taking every other field on it with the argument.
    try testing.expectEqual(
        "Element.setAttribute(\"a.b\")",
        formatArgumentKey(&buf, "Element.setAttribute", .{ .string = "a\nb" }),
    );

    // Truncated, and saying so: an argument that ends at the cap has to be
    // distinguishable from one that ends.
    const long = "x" ** 200;
    try testing.expectEqual(
        "CSS.supports(\"" ++ ("x" ** 96) ++ "...\")",
        formatArgumentKey(&buf, "CSS.supports", .{ .string = long }),
    );

    // The buffer is the last word: a key that doesn't fit falls back to the
    // member rather than emitting a half-written argument.
    var small: [8]u8 = undefined;
    try testing.expectEqual("CSS.supports", formatArgumentKey(&small, "CSS.supports", .{ .string = "flex" }));
}
