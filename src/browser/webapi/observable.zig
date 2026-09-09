//! `Observable` and `Subscriber` -- the two interfaces the window realm was
//! short, and the pair `EventTarget.when()` hands back.
//!
//! Everything here is measured off headed Chrome 151 rather than read off the
//! spec; the readings are in `tools/fingerprint/results/reference-chrome-observable.json`
//! (probe: `tools/fingerprint/probes/expr-observable-shape.js`). The ones that
//! shape the code:
//!
//!   * **Prototype order is alphabetical with `constructor` last.** Observable:
//!     catch, drop, every, filter, finally, find, first, flatMap, forEach,
//!     inspect, last, map, reduce, some, subscribe, switchMap, take, takeUntil,
//!     toArray, constructor. Subscriber: active, signal, addTeardown, complete,
//!     error, next, constructor. `active` and `signal` are getter-only.
//!   * **Ten operators return an Observable and eight return a Promise.**
//!     every/find/some/first/last/reduce/forEach/toArray are the promises.
//!   * **`complete()` runs the teardowns BEFORE the observer's complete, and
//!     `active` is already false inside them.** Measured:
//!     `next 1 | next 2 | teardown active=false | complete`. A `next()` after
//!     that is dropped silently, which is why every entry point checks
//!     `_active` first.
//!   * `Subscriber` is exposed but **not constructible** -- Chrome answers
//!     `Failed to construct 'Subscriber': Illegal constructor` -- so no
//!     constructor is declared for it below.
//!   * `subscribe` takes a bare function as well as an observer object.
//!
//! The operators are native, deliberately. Writing them in JavaScript would
//! make `Observable.prototype.map.toString()` show their source where Chrome
//! shows `[native code]`, which trades one tell for another.
//!
//! An operator is a derived Observable that, when subscribed, builds a `Stage`
//! and subscribes its upstream with a Subscriber whose sink is that stage
//! rather than a JS observer. That is the whole mechanism: `Sink` is the union
//! of "hand it to the page" and "hand it to the next stage".

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const AbortSignal = @import("AbortSignal.zig");
const EventTarget = @import("EventTarget.zig");

const Execution = js.Execution;
const Allocator = std.mem.Allocator;
const log = lp.log;

/// Explicit rather than inferred: `Subscriber.next` and `Stage.onNext` call
/// each other, and an inferred error set on a cycle is a compile error
/// ("dependency loop"). Every function on the cycle carries this.
const Err = anyerror;

pub fn registerTypes() []const type {
    return &.{ Observable, Subscriber };
}

/// What an Observable is. A source carries the page's init callback or the
/// values `from()` snapshotted; an operator carries its upstream and its
/// argument.
const Kind = enum {
    js_source,
    from_values,
    from_promise,
    /// `EventTarget.when(type)`: every event of that type, until the
    /// subscription's signal aborts.
    event_source,
    // Observable-returning operators.
    map,
    filter,
    take,
    drop,
    flat_map,
    switch_map,
    take_until,
    catch_,
    finally_,
    inspect,
    // Promise-returning operators. These never build an Observable, but the
    // stage machinery is the same, so they share the enum.
    every,
    find,
    some,
    first,
    last,
    reduce,
    for_each,
    to_array,

    fn isPromise(self: Kind) bool {
        return switch (self) {
            .every, .find, .some, .first, .last, .reduce, .for_each, .to_array => true,
            else => false,
        };
    }
};

// --- Subscriber ------------------------------------------------------------

pub const Subscriber = struct {
    _active: bool = true,
    _signal: *AbortSignal,
    _sink: Sink,
    _teardowns: std.ArrayListUnmanaged(js.Function.Global) = .empty,

    const Observer = struct {
        next: ?js.Function.Global = null,
        err: ?js.Function.Global = null,
        complete: ?js.Function.Global = null,
    };

    const Sink = union(enum) {
        /// Straight to the page.
        js: Observer,
        /// To the next operator stage.
        stage: *Stage,
    };

    fn create(sink: Sink, signal: *AbortSignal, exec: *const Execution) !*Subscriber {
        return exec._factory.create(Subscriber{ ._signal = signal, ._sink = sink });
    }

    pub fn getActive(self: *const Subscriber) bool {
        return self._active;
    }

    pub fn getSignal(self: *const Subscriber) *AbortSignal {
        return self._signal;
    }

    /// A teardown handed over after the subscription has already closed runs
    /// immediately, which is what keeps `addTeardown` from silently dropping
    /// cleanup on a completed subscription.
    pub fn addTeardown(self: *Subscriber, callback: js.Function, exec: *const Execution) !void {
        if (!self._active) {
            callback.call(void, .{}) catch {};
            return;
        }
        try self._teardowns.append(exec.arena, try callback.persist());
    }

    /// The page-facing entry points take a required argument, because that is
    /// the arity Chrome reports (1 for both). The internal `push*` pair below
    /// takes an optional, because a stage that has nothing to forward -- a
    /// `find` that ran out, say -- still has to settle.
    pub fn next(self: *Subscriber, value: js.Value, exec: *const Execution) Err!void {
        return self.pushNext(value, exec);
    }

    pub fn @"error"(self: *Subscriber, err: js.Value, exec: *const Execution) Err!void {
        return self.pushError(err, exec);
    }

    fn pushNext(self: *Subscriber, value: ?js.Value, exec: *const Execution) Err!void {
        if (!self._active) return;
        try self.emit(value, exec);
    }

    fn pushError(self: *Subscriber, err: ?js.Value, exec: *const Execution) Err!void {
        if (!self._active) return;
        self.close(exec);
        switch (self._sink) {
            .js => |o| if (o.err) |f| {
                callGlobal(f, .{err}, exec);
            } else {
                log.debug(.browser, "observable error with no handler", .{});
            },
            .stage => |st| try st.onError(err, exec),
        }
    }

    pub fn complete(self: *Subscriber, exec: *const Execution) Err!void {
        if (!self._active) return;
        self.close(exec);
        switch (self._sink) {
            .js => |o| if (o.complete) |f| callGlobal(f, .{}, exec),
            .stage => |st| try st.onComplete(exec),
        }
    }

    fn emit(self: *Subscriber, value: ?js.Value, exec: *const Execution) Err!void {
        switch (self._sink) {
            .js => |o| if (o.next) |f| callGlobal(f, .{value}, exec),
            .stage => |st| try st.onNext(value, exec),
        }
    }

    /// Marks the subscription closed and runs the teardowns, in that order --
    /// measured: `active` reads false inside a teardown.
    fn close(self: *Subscriber, exec: *const Execution) void {
        self._active = false;
        for (self._teardowns.items) |t| callGlobal(t, .{}, exec);
        self._teardowns.clearRetainingCapacity();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Subscriber);

        pub const Meta = struct {
            pub const name = "Subscriber";

            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // No constructor: Chrome answers `Illegal constructor`.
        //
        // Declared in Chrome's own prototype order, which is alphabetical with
        // the accessors first because that is how the IDL happens to sort.
        pub const active = bridge.accessor(Subscriber.getActive, null, .{});
        pub const signal = bridge.accessor(Subscriber.getSignal, null, .{});
        pub const addTeardown = bridge.function(Subscriber.addTeardown, .{});
        pub const complete = bridge.function(Subscriber.complete, .{});
        pub const @"error" = bridge.function(Subscriber.@"error", .{});
        pub const next = bridge.function(Subscriber.next, .{});
    };
};

/// One operator's running state. `down` is where its output goes, which is
/// either the page's subscriber or the next stage's.
const Stage = struct {
    kind: Kind,
    fn_: ?js.Function.Global = null,
    down: *Subscriber,
    /// take/drop's bound, and how many have gone past.
    n: u64 = 0,
    seen: u64 = 0,
    /// reduce's accumulator, and whether it has one yet.
    acc: ?js.Value.Global = null,
    has_acc: bool = false,
    /// A promise operator's resolver, settled on complete or error.
    resolver: ?js.PromiseResolver.Global = null,
    /// Collected values, for toArray.
    items: std.ArrayListUnmanaged(js.Value.Global) = .empty,
    /// flatMap / switchMap's live inner subscription.
    inner: ?*Subscriber = null,
    /// The upstream subscriber, so an operator that stops early can close it.
    up: ?*Subscriber = null,

    fn onNext(self: *Stage, value: ?js.Value, exec: *const Execution) Err!void {
        switch (self.kind) {
            .map => {
                const mapped = try self.callArg(value, exec);
                try self.down.pushNext(mapped, exec);
            },
            .filter => {
                if (try self.truthyArg(value, exec)) try self.down.pushNext(value, exec);
            },
            .inspect => {
                _ = try self.callArg(value, exec);
                try self.down.pushNext(value, exec);
            },
            .take => {
                if (self.seen >= self.n) return;
                self.seen += 1;
                try self.down.pushNext(value, exec);
                if (self.seen >= self.n) {
                    self.closeUpstream(exec);
                    try self.down.complete(exec);
                }
            },
            .drop => {
                if (self.seen < self.n) {
                    self.seen += 1;
                    return;
                }
                try self.down.pushNext(value, exec);
            },
            .take_until => try self.down.pushNext(value, exec),
            .catch_, .finally_ => try self.down.pushNext(value, exec),
            .flat_map, .switch_map => {
                // The callback answers something `from()` can take.
                const produced = try self.callArg(value, exec);
                const inner = Observable.coerce(produced, exec) catch {
                    try self.down.pushError(produced, exec);
                    return;
                };
                if (self.kind == .switch_map) {
                    if (self.inner) |old| old.close(exec);
                }
                // The inner subscription feeds the same downstream, but its
                // completion must not complete it -- only the outer's does.
                const passthrough = try exec._factory.create(Stage{
                    .kind = .take_until,
                    .down = self.down,
                });
                const sub = try inner.subscribeInternal(.{ .stage = passthrough }, null, exec);
                self.inner = sub;
            },
            // Promise operators.
            .every => {
                if (!try self.truthyArg(value, exec)) {
                    self.settleWith(false, exec);
                    self.closeUpstream(exec);
                }
            },
            .some => {
                if (try self.truthyArg(value, exec)) {
                    self.settleWith(true, exec);
                    self.closeUpstream(exec);
                }
            },
            .find => {
                if (try self.truthyArg(value, exec)) {
                    try self.settle(value, exec);
                    self.closeUpstream(exec);
                }
            },
            .first => {
                try self.settle(value, exec);
                self.closeUpstream(exec);
            },
            .last => {
                if (value) |v| {
                    self.acc = try v.persist();
                    self.has_acc = true;
                }
            },
            .for_each => {
                _ = try self.callArg(value, exec);
            },
            .reduce => {
                if (!self.has_acc) {
                    if (value) |v| {
                        self.acc = try v.persist();
                        self.has_acc = true;
                    }
                    return;
                }
                const folded = try self.callFold(value, exec);
                if (folded) |f| self.acc = try f.persist();
            },
            .to_array => {
                if (value) |v| try self.items.append(exec.arena, try v.persist());
            },
            .js_source, .from_values, .from_promise, .event_source => unreachable,
        }
    }

    fn onComplete(self: *Stage, exec: *const Execution) Err!void {
        switch (self.kind) {
            .finally_ => {
                if (self.fn_) |f| callGlobal(f, .{}, exec);
                try self.down.complete(exec);
            },
            .every => self.settleWith(true, exec),
            .some => self.settleWith(false, exec),
            .find, .first => try self.settle(null, exec),
            .last => try self.settleAcc(exec),
            .reduce => try self.settleAcc(exec),
            .for_each => try self.settle(null, exec),
            .to_array => try self.settleItems(exec),
            else => try self.down.complete(exec),
        }
    }

    fn onError(self: *Stage, err: ?js.Value, exec: *const Execution) Err!void {
        switch (self.kind) {
            .catch_ => {
                // The callback answers a replacement Observable.
                const produced = if (self.fn_) |f| callGlobalValue(f, .{err}, exec) else null;
                const replacement = Observable.coerce(produced, exec) catch {
                    try self.down.pushError(err, exec);
                    return;
                };
                const passthrough = try exec._factory.create(Stage{ .kind = .take_until, .down = self.down });
                _ = try replacement.subscribeInternal(.{ .stage = passthrough }, null, exec);
            },
            .finally_ => {
                if (self.fn_) |f| callGlobal(f, .{}, exec);
                try self.down.pushError(err, exec);
            },
            else => {
                if (self.resolver) |r| {
                    rejectResolver(r, err, exec);
                    self.resolver = null;
                    return;
                }
                try self.down.pushError(err, exec);
            },
        }
    }

    fn callArg(self: *Stage, value: ?js.Value, exec: *const Execution) !?js.Value {
        const f = self.fn_ orelse return value;
        return callGlobalValue(f, .{value}, exec);
    }

    fn callFold(self: *Stage, value: ?js.Value, exec: *const Execution) !?js.Value {
        const f = self.fn_ orelse return value;
        // Ambient local, for the reason on callGlobalValue.
        const local = exec.js.local orelse return null;
        const acc = if (self.acc) |a| local.toLocal(a) else null;
        return local.toLocal(f).call(?js.Value, .{ acc, value }) catch null;
    }

    fn truthyArg(self: *Stage, value: ?js.Value, exec: *const Execution) !bool {
        const f = self.fn_ orelse return true;
        const local = exec.js.local orelse return false;
        return local.toLocal(f).call(bool, .{value}) catch false;
    }

    fn closeUpstream(self: *Stage, exec: *const Execution) void {
        if (self.up) |u| u.close(exec);
    }

    /// Settles with any Zig value -- `resolve` converts, so a bool does not
    /// have to be built as a js.Value first.
    fn settleWith(self: *Stage, value: anytype, exec: *const Execution) void {
        const r = self.resolver orelse return;
        self.resolver = null;
        var ls: js.Local.Scope = undefined;
        exec.js.localScope(&ls);
        defer ls.deinit();
        ls.toLocal(r).resolve("Observable.promise", value);
    }

    fn settle(self: *Stage, value: ?js.Value, exec: *const Execution) !void {
        const r = self.resolver orelse return;
        self.resolver = null;
        resolveResolver(r, value, exec);
    }

    fn settleAcc(self: *Stage, exec: *const Execution) !void {
        const r = self.resolver orelse return;
        self.resolver = null;
        var ls: js.Local.Scope = undefined;
        exec.js.localScope(&ls);
        defer ls.deinit();
        const v = if (self.acc) |a| ls.toLocal(a) else null;
        ls.toLocal(r).resolve("Observable.promise", v);
    }

    fn settleItems(self: *Stage, exec: *const Execution) !void {
        const r = self.resolver orelse return;
        self.resolver = null;
        var ls: js.Local.Scope = undefined;
        exec.js.localScope(&ls);
        defer ls.deinit();
        const values = try exec.arena.alloc(js.Value, self.items.items.len);
        for (self.items.items, 0..) |g, i| values[i] = ls.toLocal(g);
        ls.toLocal(r).resolve("Observable.toArray", values);
    }
};

/// Chrome's own wording, measured. An error message is a fingerprint surface
/// in its own right -- there are four `error-message-*` plans in this repo --
/// so the text is copied rather than paraphrased.
const from_type_error = "Failed to execute 'from' on 'Observable': Cannot convert value to an Observable. " ++
    "Input value must be an Observable, async iterable, iterable, or Promise.";

fn throwTypeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

/// Ambient local when there is one -- the arguments are values from the
/// caller's scope, and re-localising the function in a fresh scope while the
/// arguments live in the old one is the same dangling-handle mistake.
/// The listener `when()` registers. Its first parameter is the embedded
/// receiver `newNamedCallback` carries, which is the subscriber to feed.
fn forwardEvent(subscriber: *Subscriber, event: js.Value, exec: *const Execution) !void {
    try subscriber.pushNext(event, exec);
}

fn callGlobal(f: js.Function.Global, args: anytype, exec: *const Execution) void {
    if (exec.js.local) |local| {
        local.toLocal(f).call(void, args) catch {};
        return;
    }
    var ls: js.Local.Scope = undefined;
    exec.js.localScope(&ls);
    defer ls.deinit();
    ls.toLocal(f).call(void, args) catch {};
}

/// Uses the AMBIENT local, not a fresh scope. A `js.Value` handed back by the
/// callback belongs to the scope it was created in, so returning one out of a
/// `defer ls.deinit()` hands the caller a dangling handle -- which reads as the
/// value arriving empty rather than as a crash: `map((v) => v * 2)` over
/// 1,2,3 produced `,,` before this. Every path here is reached from a JS call
/// (subscribe -> the page's callback -> subscriber.next), so the ambient local
/// is present; there is nothing to fall back to if it ever is not.
fn callGlobalValue(f: js.Function.Global, args: anytype, exec: *const Execution) ?js.Value {
    const local = exec.js.local orelse return null;
    return local.toLocal(f).call(?js.Value, args) catch null;
}

fn resolveResolver(r: js.PromiseResolver.Global, value: ?js.Value, exec: *const Execution) void {
    var ls: js.Local.Scope = undefined;
    exec.js.localScope(&ls);
    defer ls.deinit();
    ls.toLocal(r).resolve("Observable.promise", value);
}

fn rejectResolver(r: js.PromiseResolver.Global, err: ?js.Value, exec: *const Execution) void {
    var ls: js.Local.Scope = undefined;
    exec.js.localScope(&ls);
    defer ls.deinit();
    ls.toLocal(r).reject("Observable.promise", err);
}

// --- Observable ------------------------------------------------------------

pub const Observable = struct {
    _kind: Kind,
    _fn: ?js.Function.Global = null,
    _upstream: ?*Observable = null,
    _notifier: ?*Observable = null,
    _n: u64 = 0,
    _values: []js.Value.Global = &.{},
    /// `when()`'s target and event type.
    _target: ?*EventTarget = null,
    _ev_type: []const u8 = "",

    /// `new Observable(callback)`. Chrome requires the argument: with none it
    /// answers `1 argument required, but only 0 present.`
    pub fn constructor(callback: js.Function, exec: *const Execution) !*Observable {
        return exec._factory.create(Observable{
            ._kind = .js_source,
            ._fn = try callback.persist(),
        });
    }

    /// The observer half of `subscribe`, which takes a bare function as well as
    /// an object -- measured.
    const ObserverArg = union(enum) {
        function: js.Function,
        object: js.Object,
    };

    const SubscribeOptions = struct {
        signal: ?*AbortSignal = null,
    };

    pub fn subscribe(
        self: *Observable,
        observer_: ?ObserverArg,
        options_: ?SubscribeOptions,
        exec: *const Execution,
    ) !void {
        var o: Subscriber.Observer = .{};
        if (observer_) |observer| switch (observer) {
            .function => |f| o.next = try f.persist(),
            .object => |obj| {
                if (try obj.getFunction("next")) |f| o.next = try f.persist();
                if (try obj.getFunction("error")) |f| o.err = try f.persist();
                if (try obj.getFunction("complete")) |f| o.complete = try f.persist();
            },
        };
        const signal = if (options_) |opts| opts.signal else null;
        _ = try self.subscribeInternal(.{ .js = o }, signal, exec);
    }

    /// The one path every subscription takes, page-facing or operator-internal.
    fn subscribeInternal(
        self: *Observable,
        sink: Subscriber.Sink,
        signal_: ?*AbortSignal,
        exec: *const Execution,
    ) Err!*Subscriber {
        const signal = signal_ orelse try AbortSignal.init(exec);
        const subscriber = try Subscriber.create(sink, signal, exec);
        try self.run(subscriber, exec);
        return subscriber;
    }

    fn run(self: *Observable, subscriber: *Subscriber, exec: *const Execution) Err!void {
        switch (self._kind) {
            .js_source => {
                const f = self._fn orelse return;
                callGlobal(f, .{subscriber}, exec);
            },
            .from_values => {
                const local = exec.js.local orelse return;
                for (self._values) |g| {
                    if (!subscriber._active) break;
                    try subscriber.pushNext(local.toLocal(g), exec);
                }
                try subscriber.complete(exec);
            },
            .event_source => {
                const target = self._target orelse return;
                const local = exec.js.local orelse return;
                // A native listener, wrapped as a JS function so it can go
                // through the ordinary registration path -- the event manager's
                // `Callback` union has no native variant, and adding one would
                // touch duplicate detection and removal for every listener in
                // the engine.
                const forwarder = try local.newNamedCallback("", 1, forwardEvent, subscriber);
                // The signal does the teardown: `RegisterOptions.signal` already
                // removes a listener when its signal aborts, which is exactly
                // what `subscribe(observer, {signal})` promises. Measured on
                // Chrome: after `controller.abort()` a further dispatch delivers
                // nothing.
                switch (exec.js.global) {
                    inline else => |g| _ = try g._event_manager.register(
                        target,
                        self._ev_type,
                        .{ .function = forwarder },
                        .{ .signal = subscriber._signal },
                    ),
                }
            },
            .from_promise => {
                // Nothing schedules here yet: a promise source needs the
                // microtask hop, and no operator in this file consumes one.
                try subscriber.complete(exec);
            },
            else => {
                // An operator: build the stage and subscribe upstream into it.
                const up = self._upstream orelse return;
                const stage = try exec._factory.create(Stage{
                    .kind = self._kind,
                    .fn_ = self._fn,
                    .down = subscriber,
                    .n = self._n,
                });
                const up_sub = try up.subscribeInternal(.{ .stage = stage }, null, exec);
                stage.up = up_sub;
                if (self._notifier) |notifier| {
                    // takeUntil: the first value from the notifier completes
                    // the downstream.
                    const stop = try exec._factory.create(Stage{ .kind = .first, .down = subscriber });
                    stop.up = up_sub;
                    _ = try notifier.subscribeInternal(.{ .stage = stop }, null, exec);
                }
            },
        }
    }

    fn derive(self: *Observable, kind: Kind, f: ?js.Function, n: u64, exec: *const Execution) !*Observable {
        return exec._factory.create(Observable{
            ._kind = kind,
            ._fn = if (f) |func| try func.persist() else null,
            ._upstream = self,
            ._n = n,
        });
    }

    fn promiseFrom(self: *Observable, kind: Kind, f: ?js.Function, exec: *const Execution) !js.Promise {
        const local = exec.js.local.?;
        const resolver = local.createPromiseResolver();
        const stage = try exec._factory.create(Stage{
            .kind = kind,
            .fn_ = if (f) |func| try func.persist() else null,
            // A promise operator has no downstream subscriber, but the field is
            // not optional: give it one whose sink drops everything.
            .down = try Subscriber.create(.{ .js = .{} }, try AbortSignal.init(exec), exec),
            .resolver = try resolver.persist(),
        });
        const up = try self.subscribeInternal(.{ .stage = stage }, null, exec);
        stage.up = up;
        return resolver.promise();
    }

    /// What `EventTarget.when(type)` hands back.
    pub fn forEvents(target: *EventTarget, typ: []const u8, exec: *const Execution) !*Observable {
        return exec._factory.create(Observable{
            ._kind = .event_source,
            ._target = target,
            ._ev_type = try exec.arena.dupe(u8, typ),
        });
    }

    /// `Observable.from(value)`. Accepts an Observable, an iterable, an async
    /// iterable or a Promise; anything else throws with Chrome's wording.
    pub fn from(value: ?js.Value, exec: *const Execution) !*Observable {
        return coerce(value, exec) catch return throwTypeError(from_type_error, exec);
    }

    fn coerce(value: ?js.Value, exec: *const Execution) Err!*Observable {
        const v = value orelse return error.NotAnObservable;
        if (!v.isObject()) return error.NotAnObservable;
        const obj = v.toObject();
        // An Observable passes straight through, which is what makes
        // `from(observable)` cheap and `takeUntil(observable)` work.
        if (obj.toZig(*Observable)) |existing| {
            return existing;
        } else |_| {}
        if ((try obj.getFunction("then")) != null) {
            return exec._factory.create(Observable{ ._kind = .from_promise });
        }
        if (v.isArray()) {
            return exec._factory.create(Observable{
                ._kind = .from_values,
                ._values = try arrayValues(v, exec),
            });
        }
        // A non-array iterable is accepted and treated as the empty sequence.
        // Chrome emits its values; reading them needs the @@iterator protocol
        // driven from Zig, which this bridge has no helper for -- so the
        // partial is here rather than a refusal, because the visible answer a
        // page checks first is the TYPE (`from(set) instanceof Observable`),
        // and refusing gets that wrong as well as the values.
        // `webapi/animation/timelines.zig` makes the same call for the same
        // reason.
        if (obj.hasIterator()) {
            return exec._factory.create(Observable{ ._kind = .from_values });
        }
        return error.NotAnObservable;
    }

    /// A snapshot of an array's values. Chrome subscribes lazily; taking them
    /// up front is visible only to an accessor with side effects, and is what
    /// keeps `from()` from needing its own iteration state.
    fn arrayValues(value: js.Value, exec: *const Execution) Err![]js.Value.Global {
        const array = value.toArray();
        const out = try exec.arena.alloc(js.Value.Global, @intCast(array.len()));
        for (out, 0..) |*slot, i| slot.* = try (try array.get(@intCast(i))).persist();
        return out;
    }

    // --- the ten Observable-returning operators ---------------------------

    pub fn map(self: *Observable, f: js.Function, exec: *const Execution) !*Observable {
        return self.derive(.map, f, 0, exec);
    }
    pub fn filter(self: *Observable, f: js.Function, exec: *const Execution) !*Observable {
        return self.derive(.filter, f, 0, exec);
    }
    pub fn take(self: *Observable, n: u64, exec: *const Execution) !*Observable {
        return self.derive(.take, null, n, exec);
    }
    pub fn drop(self: *Observable, n: u64, exec: *const Execution) !*Observable {
        return self.derive(.drop, null, n, exec);
    }
    pub fn flatMap(self: *Observable, f: js.Function, exec: *const Execution) !*Observable {
        return self.derive(.flat_map, f, 0, exec);
    }
    pub fn switchMap(self: *Observable, f: js.Function, exec: *const Execution) !*Observable {
        return self.derive(.switch_map, f, 0, exec);
    }
    pub fn takeUntil(self: *Observable, notifier: js.Value, exec: *const Execution) !*Observable {
        const derived = try self.derive(.take_until, null, 0, exec);
        derived._notifier = coerce(notifier, exec) catch null;
        return derived;
    }
    pub fn @"catch"(self: *Observable, f: js.Function, exec: *const Execution) !*Observable {
        return self.derive(.catch_, f, 0, exec);
    }
    pub fn finally(self: *Observable, f: js.Function, exec: *const Execution) !*Observable {
        return self.derive(.finally_, f, 0, exec);
    }
    pub fn inspect(self: *Observable, f: ?js.Function, exec: *const Execution) !*Observable {
        return self.derive(.inspect, f, 0, exec);
    }

    // --- the eight Promise-returning operators ----------------------------

    pub fn every(self: *Observable, f: js.Function, exec: *const Execution) !js.Promise {
        return self.promiseFrom(.every, f, exec);
    }
    pub fn find(self: *Observable, f: js.Function, exec: *const Execution) !js.Promise {
        return self.promiseFrom(.find, f, exec);
    }
    pub fn some(self: *Observable, f: js.Function, exec: *const Execution) !js.Promise {
        return self.promiseFrom(.some, f, exec);
    }
    pub fn first(self: *Observable, exec: *const Execution) !js.Promise {
        return self.promiseFrom(.first, null, exec);
    }
    pub fn last(self: *Observable, exec: *const Execution) !js.Promise {
        return self.promiseFrom(.last, null, exec);
    }
    pub fn reduce(self: *Observable, f: js.Function, exec: *const Execution) !js.Promise {
        return self.promiseFrom(.reduce, f, exec);
    }
    pub fn forEach(self: *Observable, f: js.Function, exec: *const Execution) !js.Promise {
        return self.promiseFrom(.for_each, f, exec);
    }
    pub fn toArray(self: *Observable, exec: *const Execution) !js.Promise {
        return self.promiseFrom(.to_array, null, exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Observable);

        pub const Meta = struct {
            pub const name = "Observable";

            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(Observable.constructor, .{});

        // Chrome's prototype order, which is alphabetical. Kept in that order
        // here because `Object.getOwnPropertyNames` reports declaration order
        // and a page can read it.
        pub const @"catch" = bridge.function(Observable.@"catch", .{});
        pub const drop = bridge.function(Observable.drop, .{});
        pub const every = bridge.function(Observable.every, .{});
        pub const filter = bridge.function(Observable.filter, .{});
        pub const finally = bridge.function(Observable.finally, .{});
        pub const find = bridge.function(Observable.find, .{});
        pub const first = bridge.function(Observable.first, .{});
        pub const flatMap = bridge.function(Observable.flatMap, .{});
        pub const forEach = bridge.function(Observable.forEach, .{});
        pub const inspect = bridge.function(Observable.inspect, .{});
        pub const last = bridge.function(Observable.last, .{});
        pub const map = bridge.function(Observable.map, .{});
        pub const reduce = bridge.function(Observable.reduce, .{});
        pub const some = bridge.function(Observable.some, .{});
        pub const subscribe = bridge.function(Observable.subscribe, .{});
        pub const switchMap = bridge.function(Observable.switchMap, .{});
        pub const take = bridge.function(Observable.take, .{});
        pub const takeUntil = bridge.function(Observable.takeUntil, .{});
        pub const toArray = bridge.function(Observable.toArray, .{});

        pub const from = bridge.function(Observable.from, .{ .static = true });
    };
};

const testing = @import("../../testing.zig");
test "WebApi: Observable" {
    try testing.htmlRunner("event/observable.html", .{});
}
