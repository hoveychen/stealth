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

// https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#the-constraint-validation-api

const js = @import("../../../js/js.zig");

const Element = @import("../../Element.zig");
const Input = @import("Input.zig");
const Select = @import("Select.zig");
const TextArea = @import("TextArea.zig");
const Button = @import("Button.zig");
const Frame = @import("../../../Frame.zig");

const ValidityState = @This();

// The form control whose validity flags this object reflects. Stored as a
// generic *Element; each getter dispatches on the concrete element type
// because the flag definitions are per-type in the HTML spec.
_owner: *Element,

// A form-associated custom element has no per-type flag definitions at all: its
// page sets the whole set at once through ElementInternals.setValidity, and this
// object is a live view of that set. When it is non-null every getter reads it
// instead of dispatching on the element type.
_flags: ?*const Flags = null,

/// The flag set ElementInternals.setValidity writes. Named after the
/// ValidityStateFlags dictionary members, minus `valid`, which is derived.
pub const Flags = struct {
    value_missing: bool = false,
    type_mismatch: bool = false,
    pattern_mismatch: bool = false,
    too_long: bool = false,
    too_short: bool = false,
    range_underflow: bool = false,
    range_overflow: bool = false,
    step_mismatch: bool = false,
    bad_input: bool = false,
    custom_error: bool = false,

    pub fn isValid(self: *const Flags) bool {
        return !self.value_missing and !self.type_mismatch and !self.pattern_mismatch and
            !self.too_long and !self.too_short and !self.range_underflow and
            !self.range_overflow and !self.step_mismatch and !self.bad_input and
            !self.custom_error;
    }
};

pub fn getValueMissing(self: *const ValidityState, frame: *Frame) bool {
    if (self._flags) |flags| return flags.value_missing;
    if (self._owner.is(Input)) |input| return input.suffersValueMissing(frame);
    if (self._owner.is(Select)) |select| return select.suffersValueMissing();
    if (self._owner.is(TextArea)) |textarea| return textarea.suffersValueMissing();
    return false;
}

pub fn getTypeMismatch(self: *const ValidityState) bool {
    if (self._flags) |flags| return flags.type_mismatch;
    if (self._owner.is(Input)) |input| return input.suffersTypeMismatch();
    return false;
}

pub fn getPatternMismatch(self: *const ValidityState, frame: *Frame) bool {
    if (self._flags) |flags| return flags.pattern_mismatch;
    if (self._owner.is(Input)) |input| return input.suffersPatternMismatch(frame);
    return false;
}

pub fn getTooLong(self: *const ValidityState) bool {
    if (self._flags) |flags| return flags.too_long;
    if (self._owner.is(Input)) |input| return input.suffersTooLong();
    if (self._owner.is(TextArea)) |textarea| return textarea.suffersTooLong();
    return false;
}

pub fn getTooShort(self: *const ValidityState) bool {
    if (self._flags) |flags| return flags.too_short;
    if (self._owner.is(Input)) |input| return input.suffersTooShort();
    if (self._owner.is(TextArea)) |textarea| return textarea.suffersTooShort();
    return false;
}

pub fn getRangeUnderflow(self: *const ValidityState) bool {
    if (self._flags) |flags| return flags.range_underflow;
    if (self._owner.is(Input)) |input| return input.suffersRangeUnderflow();
    return false;
}

pub fn getRangeOverflow(self: *const ValidityState) bool {
    if (self._flags) |flags| return flags.range_overflow;
    if (self._owner.is(Input)) |input| return input.suffersRangeOverflow();
    return false;
}

pub fn getStepMismatch(self: *const ValidityState) bool {
    if (self._flags) |flags| return flags.step_mismatch;
    // Step matching is not implemented yet (PR #2280 begins step rounding for
    // <input type=range>). Returning false keeps well-formed values valid.
    return false;
}

pub fn getBadInput(self: *const ValidityState) bool {
    if (self._flags) |flags| return flags.bad_input;
    // badInput flips when the UA cannot convert a user-typed string (e.g. the
    // user typed "abc" into <input type=number>). Headless Lightpanda receives
    // values via attributes or JS assignment, never raw keystrokes — there is
    // no user input to be "bad". Always false.
    return false;
}

pub fn getCustomError(self: *const ValidityState) bool {
    if (self._flags) |flags| return flags.custom_error;
    if (self._owner.is(Input)) |input| return input.hasCustomValidity();
    if (self._owner.is(Select)) |select| return select.hasCustomValidity();
    if (self._owner.is(TextArea)) |textarea| return textarea.hasCustomValidity();
    if (self._owner.is(Button)) |button| return button.hasCustomValidity();
    return false;
}

pub fn getValid(self: *const ValidityState, frame: *Frame) bool {
    if (self._flags) |flags| return flags.isValid();
    return !self.getValueMissing(frame) and
        !self.getTypeMismatch() and
        !self.getPatternMismatch(frame) and
        !self.getTooLong() and
        !self.getTooShort() and
        !self.getRangeUnderflow() and
        !self.getRangeOverflow() and
        !self.getStepMismatch() and
        !self.getBadInput() and
        !self.getCustomError();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ValidityState);

    pub const Meta = struct {
        pub const name = "ValidityState";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const valueMissing = bridge.accessor(ValidityState.getValueMissing, null, .{});
    pub const typeMismatch = bridge.accessor(ValidityState.getTypeMismatch, null, .{});
    pub const patternMismatch = bridge.accessor(ValidityState.getPatternMismatch, null, .{});
    pub const tooLong = bridge.accessor(ValidityState.getTooLong, null, .{});
    pub const tooShort = bridge.accessor(ValidityState.getTooShort, null, .{});
    pub const rangeUnderflow = bridge.accessor(ValidityState.getRangeUnderflow, null, .{});
    pub const rangeOverflow = bridge.accessor(ValidityState.getRangeOverflow, null, .{});
    pub const stepMismatch = bridge.accessor(ValidityState.getStepMismatch, null, .{});
    pub const badInput = bridge.accessor(ValidityState.getBadInput, null, .{});
    pub const customError = bridge.accessor(ValidityState.getCustomError, null, .{});
    pub const valid = bridge.accessor(ValidityState.getValid, null, .{});
};
