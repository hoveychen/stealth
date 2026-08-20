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
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

//! window.scheduler: the Prioritized Task Scheduling API.
//!
//! A posted task really does run, on the engine's own scheduler, and really
//! does run in priority order: a user-blocking task queued last still goes
//! first, and a yield() continuation outranks every pending task. That order
//! is what a script can observe, and it is what was measured on a headed
//! Chrome 150 over http://localhost (the win10 probes in
//! tools/fingerprint/results/probes/).
//!
//! Every argument error on postTask is a rejection rather than a synchronous
//! throw -- measured, all seven of them -- while setPriority, TaskSignal.any
//! and both constructors throw, because they hand back no promise to reject.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");

const Event = @import("Event.zig");
const EventTarget = @import("EventTarget.zig");
const AbortSignal = @import("AbortSignal.zig");
const AbortController = @import("AbortController.zig");
const handler_property = @import("handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

const String = lp.String;
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        Scheduler,
        TaskController,
        TaskSignal,
        TaskPriorityChangeEvent,
    };
}

/// The TaskPriority enum. The three names are the only values any of the
/// entry points accept; everything else is the WebIDL enum TypeError.
pub const Priority = enum {
    user_blocking,
    user_visible,
    background,

    fn fromString(value: []const u8) ?Priority {
        if (std.mem.eql(u8, value, "user-blocking")) return .user_blocking;
        if (std.mem.eql(u8, value, "user-visible")) return .user_visible;
        if (std.mem.eql(u8, value, "background")) return .background;
        return null;
    }

    fn toString(self: Priority) []const u8 {
        return switch (self) {
            .user_blocking => "user-blocking",
            .user_visible => "user-visible",
            .background => "background",
        };
    }
};

// Where a queued piece of work sits relative to the others. A yield()
// continuation ranks above every posted task, whatever its priority: measured,
// a yield issued after a task still resolves first.
const Rank = enum(u8) {
    continuation = 0,
    user_blocking = 1,
    user_visible = 2,
    background = 3,

    fn of(priority: Priority) Rank {
        return switch (priority) {
            .user_blocking => .user_blocking,
            .user_visible => .user_visible,
            .background => .background,
        };
    }
};

fn throwTypeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

// "The provided value 'x' is not a valid enum value of type TaskPriority",
// with whatever prefix the caller's operation carries.
fn enumTypeError(comptime prefix: []const u8, value: []const u8, exec: *const Execution) anyerror {
    const message = std.fmt.allocPrint(
        exec.call_arena,
        prefix ++ "The provided value '{s}' is not a valid enum value of type TaskPriority.",
        .{value},
    ) catch return error.TypeError;
    return throwTypeError(message, exec);
}

// Reads a dictionary's `priority` member. An absent or undefined member means
// "leave it at the default"; anything else has to name one of the three
// priorities, stringified the way WebIDL stringifies it for the message.
fn readPriority(
    options_: ?js.Value,
    comptime prefix: []const u8,
    exec: *const Execution,
) !?Priority {
    const options = options_ orelse return null;
    if (!options.isObject()) {
        return null;
    }
    const value = try options.toObject().get("priority");
    if (value.isUndefined()) {
        return null;
    }
    const text = try value.toStringSlice();
    return Priority.fromString(text) orelse enumTypeError(prefix, text, exec);
}

pub const Scheduler = struct {
    // Everything queued and not yet run, in no particular order: the pick
    // happens at run time so a task posted later can still go first.
    _tasks: std.ArrayListUnmanaged(*Task) = .empty,

    pub const init: Scheduler = .{};

    pub fn postTask(
        self: *Scheduler,
        callback_: ?js.Value,
        options_: ?js.Value,
        exec: *Execution,
    ) !js.Promise {
        const local = exec.js.local.?;

        const callback_value = callback_ orelse return local.rejectPromise(.{
            .type_error = "Failed to execute 'postTask' on 'Scheduler': 1 argument required, but only 0 present.",
        });
        if (!callback_value.isFunction()) {
            return local.rejectPromise(.{
                .type_error = "Failed to execute 'postTask' on 'Scheduler': parameter 1 is not of type 'Function'.",
            });
        }

        const options = Options.read(options_) catch |err| switch (err) {
            error.BadPriority => return local.rejectPromise(.{
                .type_error = try optionTypeError("priority", options_.?, exec),
            }),
            error.BadSignal => return local.rejectPromise(.{
                .type_error = "Failed to execute 'postTask' on 'Scheduler': Failed to read the 'signal' " ++
                    "property from 'SchedulerPostTaskOptions': Failed to convert value to 'AbortSignal'.",
            }),
            error.BadDelay => return local.rejectPromise(.{
                .type_error = "Failed to execute 'postTask' on 'Scheduler': Failed to read the 'delay' " ++
                    "property from 'SchedulerPostTaskOptions': Value is outside the 'unsigned long long' value range.",
            }),
            else => return err,
        };

        // An already-aborted signal never lets the callback run at all.
        if (options.signal) |signal| {
            if (signal.getAborted()) {
                const resolver = local.createPromiseResolver();
                resolver.reject("Scheduler.postTask", signal.getReason());
                return resolver.promise();
            }
        }

        const callback = try (try callback_value.toZig(js.Function)).persist();
        errdefer callback.release();

        return self.queue(.{
            .callback = callback,
            .signal = options.signal,
            .rank = Rank.of(options.priority orelse .user_visible),
            .delay = options.delay,
        }, exec);
    }

    // yield() hands back a promise that resolves with undefined once the
    // scheduler gets back to it. Its argument is read and ignored, exactly as
    // Chrome does -- even `{priority: 'bogus'}` resolves.
    pub fn yield(self: *Scheduler, _: ?js.Value, exec: *Execution) !js.Promise {
        return self.queue(.{
            .callback = null,
            .signal = null,
            .rank = .continuation,
            .delay = 0,
        }, exec);
    }

    const Queued = struct {
        callback: ?js.Function.Global,
        signal: ?*AbortSignal,
        rank: Rank,
        delay: u32,
    };

    fn queue(self: *Scheduler, queued: Queued, exec: *Execution) !js.Promise {
        const local = exec.js.local.?;
        const resolver = local.createPromiseResolver();

        const task = try exec.arena.create(Task);
        task.* = .{
            .exec = exec,
            .scheduler = self,
            .rank = queued.rank,
            .signal = queued.signal,
            .callback = queued.callback,
            .resolver = try resolver.persist(),
            .sequence = self._tasks.items.len,
            .run_at = lp.datetime.milliTimestamp(.boot) + queued.delay,
        };
        try self._tasks.append(exec.arena, task);
        errdefer _ = self._tasks.pop();

        // One engine task per queued task. Which of them a given firing
        // actually runs is decided in runNext, so the firings act as slots
        // rather than as a fixed order.
        try exec._scheduler.add(task, Task.run, queued.delay, .{ .name = "scheduler.postTask" });
        return resolver.promise();
    }

    // Runs the highest-ranked task whose time has come. The task that owns the
    // firing is due by construction, so this always finds one -- unless it was
    // already run by an earlier firing, in which case there is nothing to do.
    fn runNext(self: *Scheduler) void {
        const now = lp.datetime.milliTimestamp(.boot);

        var best: ?usize = null;
        for (self._tasks.items, 0..) |task, i| {
            if (task.run_at > now) {
                continue;
            }
            const current = best orelse {
                best = i;
                continue;
            };
            if (task.before(self._tasks.items[current])) {
                best = i;
            }
        }

        const index = best orelse return;
        const task = self._tasks.orderedRemove(index);
        task.execute();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Scheduler);

        pub const Meta = struct {
            pub const name = "Scheduler";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // Chrome's own prototype order.
        pub const postTask = bridge.function(Scheduler.postTask, .{ .arity = 1 });
        pub const yield = bridge.function(Scheduler.yield, .{ .arity = 0 });
    };
};

const Task = struct {
    exec: *Execution,
    scheduler: *Scheduler,
    rank: Rank,
    // Posting order, the tie-breaker within a rank.
    sequence: usize,
    run_at: u64,
    signal: ?*AbortSignal,
    // null for a yield() continuation, which resolves with undefined.
    callback: ?js.Function.Global,
    resolver: js.PromiseResolver.Global,

    fn before(self: *const Task, other: *const Task) bool {
        const self_rank = @intFromEnum(self.rank);
        const other_rank = @intFromEnum(other.rank);
        if (self_rank != other_rank) {
            return self_rank < other_rank;
        }
        return self.sequence < other.sequence;
    }

    fn run(ptr: *anyopaque) !?u32 {
        const self: *Task = @ptrCast(@alignCast(ptr));
        self.scheduler.runNext();
        return null;
    }

    fn release(self: *Task) void {
        if (self.callback) |callback| {
            callback.release();
        }
        self.resolver.deinit();
    }

    fn execute(self: *Task) void {
        defer self.release();

        var ls: js.Local.Scope = undefined;
        self.exec.js.localScope(&ls);
        defer ls.deinit();

        const local = &ls.local;
        const resolver = self.resolver.local(local);

        // A signal aborted while the task waited its turn rejects it with the
        // signal's reason instead of running the callback.
        if (self.signal) |signal| {
            if (signal.getAborted()) {
                resolver.reject("Scheduler.postTask", signal.getReason());
                return;
            }
        }

        const callback = self.callback orelse {
            resolver.resolve("Scheduler.yield", {});
            return;
        };

        // The promise takes on whatever the callback returns, including a
        // promise of its own, and takes on whatever it throws.
        var try_catch: js.TryCatch = undefined;
        try_catch.init(local);
        defer try_catch.deinit();

        const value = local.toLocal(callback).callRethrow(js.Value, .{}) catch |err| {
            if (err == error.ExecutionTerminated) {
                return;
            }
            if (try_catch.exceptionValue()) |exception| {
                resolver.reject("Scheduler.postTask", exception);
            } else {
                resolver.rejectError("Scheduler.postTask", .{ .generic_error = @errorName(err) });
            }
            return;
        };
        resolver.resolve("Scheduler.postTask", value);
        local.runMicrotasks();
    }
};

// SchedulerPostTaskOptions. Read by hand rather than as a bridge struct so each
// member's failure carries Chrome's own wording.
const Options = struct {
    priority: ?Priority = null,
    signal: ?*AbortSignal = null,
    delay: u32 = 0,

    const ReadError = error{ BadPriority, BadSignal, BadDelay };

    fn read(options_: ?js.Value) !Options {
        const options = options_ orelse return .{};
        if (!options.isObject()) {
            return .{};
        }
        const object = options.toObject();

        var out: Options = .{};

        const priority = try object.get("priority");
        if (!priority.isUndefined()) {
            const text = try priority.toStringSlice();
            out.priority = Priority.fromString(text) orelse return error.BadPriority;
        }

        const signal = try object.get("signal");
        if (!signal.isUndefined()) {
            out.signal = signal.toZig(*AbortSignal) catch return error.BadSignal;
        }

        const delay = try object.get("delay");
        if (!delay.isUndefined()) {
            const ms = delay.toF64() catch return error.BadDelay;
            if (std.math.isNan(ms)) {
                out.delay = 0;
            } else if (ms < 0 or ms > std.math.maxInt(u32)) {
                return error.BadDelay;
            } else {
                out.delay = @intFromFloat(ms);
            }
        }

        return out;
    }
};

// The priority member's message needs the value that was rejected, which the
// error set cannot carry, so it is re-read here.
fn optionTypeError(comptime member: []const u8, options: js.Value, exec: *const Execution) ![]const u8 {
    const value = try options.toObject().get(member);
    const text = try value.toStringSlice();
    return std.fmt.allocPrint(
        exec.call_arena,
        "Failed to execute 'postTask' on 'Scheduler': Failed to read the '" ++ member ++
            "' property from 'SchedulerPostTaskOptions': The provided value '{s}' is not a valid " ++
            "enum value of type TaskPriority.",
        .{text},
    );
}

/// An AbortSignal that also carries a priority. Instances reach JS as their
/// most specific type through AbortSignal's `_type`, which is why a
/// prioritychange event's target reads back as a TaskSignal.
pub const TaskSignal = struct {
    pub const Proto = AbortSignal;

    _proto: *AbortSignal,
    _priority: Priority,

    pub fn init(priority: Priority, exec: *const Execution) !*TaskSignal {
        const signal = try exec._factory.chained(.{
            EventTarget{ ._type = undefined },
            AbortSignal{ ._proto = undefined },
            TaskSignal{ ._proto = undefined, ._priority = priority },
        });
        signal._proto._proto._type = .abort_signal;
        signal._proto._type = .{ .task_signal = signal };
        return signal;
    }

    pub fn asAbortSignal(self: *TaskSignal) *AbortSignal {
        return self._proto;
    }

    pub fn getPriority(self: *const TaskSignal) []const u8 {
        return self._priority.toString();
    }

    // TaskSignal.any() takes no priority source, so the signal it returns is
    // always user-visible even when a source signal is not (measured).
    pub fn any(signals_: ?js.Value, exec: *const Execution) !*TaskSignal {
        const value = signals_ orelse return throwTypeError(
            "Failed to execute 'any' on 'TaskSignal': 1 argument required, but only 0 present.",
            exec,
        );
        const signals = try value.toZig([]const *AbortSignal);
        const result = try TaskSignal.init(.user_visible, exec);
        try AbortSignal.linkAny(result._proto, signals, exec);
        return result;
    }

    pub fn asEventTarget(self: *TaskSignal) *EventTarget {
        return self._proto.asEventTarget();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(TaskSignal);

        pub const Meta = struct {
            pub const name = "TaskSignal";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = AbortSignal;

        pub const priority = bridge.accessor(TaskSignal.getPriority, null, .{});
        pub const onprioritychange = bridge.accessor(handlerProperty(TaskSignal, .onprioritychange).get, handlerProperty(TaskSignal, .onprioritychange).set, .{});

        pub const any = bridge.function(TaskSignal.any, .{ .static = true, .arity = 1 });
    };
};

/// An AbortController whose signal is a TaskSignal, and which can change that
/// signal's priority after the fact.
pub const TaskController = struct {
    pub const Proto = AbortController;

    _proto: *AbortController,
    _signal: *TaskSignal,

    pub fn constructor(options_: ?js.Value, exec: *const Execution) !*TaskController {
        const priority = try readPriority(
            options_,
            "Failed to construct 'TaskController': Failed to read the 'priority' property from " ++
                "'TaskControllerInit': ",
            exec,
        );
        const signal = try TaskSignal.init(priority orelse .user_visible, exec);
        return exec._factory.chained(.{
            AbortController{ ._signal = signal.asAbortSignal() },
            TaskController{ ._proto = undefined, ._signal = signal },
        });
    }

    // Setting the priority it already has is a no-op: no event fires
    // (measured).
    pub fn setPriority(self: *TaskController, priority_: ?js.Value, exec: *const Execution) !void {
        const value = priority_ orelse return throwTypeError(
            "Failed to execute 'setPriority' on 'TaskController': 1 argument required, but only 0 present.",
            exec,
        );
        const text = try value.toStringSlice();
        const priority = Priority.fromString(text) orelse return enumTypeError(
            "Failed to execute 'setPriority' on 'TaskController': ",
            text,
            exec,
        );

        const signal = self._signal;
        const previous = signal._priority;
        if (previous == priority) {
            return;
        }
        // The new priority is already readable from the event's target, so it
        // is written before the event goes out.
        signal._priority = priority;

        const target = signal._proto.asEventTarget();
        const handler = null;
        switch (exec.js.global) {
            inline else => |g| {
                if (!g._event_manager.hasDirectListeners(target, "prioritychange", handler)) {
                    return;
                }
                const event = try TaskPriorityChangeEvent.initTrusted(previous, exec);
                try g.dispatch(target, event.asEvent(), handler, .{ .context = "prioritychange" });
            },
        }
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(TaskController);

        pub const Meta = struct {
            pub const name = "TaskController";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = AbortController;

        pub const constructor = bridge.constructor(TaskController.constructor, .{ .arity = 0 });
        pub const setPriority = bridge.function(TaskController.setPriority, .{ .arity = 1 });
    };
};

/// The event setPriority dispatches. previousPriority is a required member of
/// its init dictionary, so both the missing-dictionary and the
/// missing-member errors have their own wording.
pub const TaskPriorityChangeEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _previous_priority: Priority,

    const EventOptions = Event.inheritOptions(TaskPriorityChangeEvent, struct {
        previousPriority: ?[]const u8 = null,
    });

    // A missing second argument and an explicit `undefined` one are the same
    // value by the time the bridge hands them over, so both take the
    // "2 arguments required" message; Chrome gives the second one the
    // required-member message instead.
    pub fn constructor(typ: []const u8, options_: ?EventOptions, exec: *const Execution) !*TaskPriorityChangeEvent {
        const options = options_ orelse return throwTypeError(
            "Failed to construct 'TaskPriorityChangeEvent': 2 arguments required, but only 1 present.",
            exec,
        );
        const text = options.previousPriority orelse return throwTypeError(
            "Failed to construct 'TaskPriorityChangeEvent': Failed to read the 'previousPriority' property " ++
                "from 'TaskPriorityChangeEventInit': Required member is undefined.",
            exec,
        );
        const previous = Priority.fromString(text) orelse return enumTypeError(
            "Failed to construct 'TaskPriorityChangeEvent': Failed to read the 'previousPriority' property " ++
                "from 'TaskPriorityChangeEventInit': ",
            text,
            exec,
        );

        const arena = try exec.getArena(.tiny, "TaskPriorityChangeEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try String.init(arena.allocator(), typ, .{}),
            TaskPriorityChangeEvent{ ._proto = undefined, ._previous_priority = previous },
        );
        Event.populatePrototypes(event, options, false);
        return event;
    }

    fn initTrusted(previous: Priority, exec: *const Execution) !*TaskPriorityChangeEvent {
        const arena = try exec.getArena(.tiny, "TaskPriorityChangeEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try String.init(arena.allocator(), "prioritychange", .{}),
            TaskPriorityChangeEvent{ ._proto = undefined, ._previous_priority = previous },
        );
        Event.populatePrototypes(event, EventOptions{}, true);
        return event;
    }

    pub fn asEvent(self: *TaskPriorityChangeEvent) *Event {
        return self._proto;
    }

    pub fn getPreviousPriority(self: *const TaskPriorityChangeEvent) []const u8 {
        return self._previous_priority.toString();
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(TaskPriorityChangeEvent);

        pub const Meta = struct {
            pub const name = "TaskPriorityChangeEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Event;

        pub const constructor = bridge.constructor(TaskPriorityChangeEvent.constructor, .{ .arity = 2 });
        pub const previousPriority = bridge.accessor(TaskPriorityChangeEvent.getPreviousPriority, null, .{});
    };
};
