// The constraint-validation API as it behaves on the three form-associated
// elements that are *barred from constraint validation*: fieldset, output and
// object. Button/Input/Select/TextArea each have their own flag definitions;
// these three have none, so the whole surface collapses to one shape and is
// worth sharing rather than writing out three times.
//
// Measured on a headed Chrome 151
// (`probes/expr-form-associated-barred.js`, all three elements identical):
//
// | reading | before setCustomValidity | after setCustomValidity('boom') |
// |---|---|---|
// | `willValidate` | false | false |
// | `validity.customError` | false | **true** |
// | `validity.valid` | true | **false** |
// | `validationMessage` | "" | **""** |
// | `checkValidity()` | true | true |
// | `invalid` event | – | not fired |
//
// So the custom message *is* stored and *is* visible through the ValidityState
// -- the barring only reaches willValidate, validationMessage, checkValidity
// and the event. Returning false from `hasCustomValidity` because the element
// will never validate would be the plausible reading and it is the wrong one.
//
// `validity` hands back the same object every time (measured), so it is created
// once and cached on the element.

const Frame = @import("../../../Frame.zig");
const Form = @import("Form.zig");
const ValidityState = @import("ValidityState.zig");

/// Mixes into an element that carries `_custom_validity: ?[]const u8` and
/// `_validity: ?*ValidityState` fields and an `asElement` / `asConstElement`
/// pair.
pub fn Mixin(comptime T: type) type {
    return struct {
        pub fn getForm(self: *T, frame: *Frame) ?*Form {
            return Form.ownerOf(self.asElement(), frame);
        }

        pub fn getWillValidate(_: *const T) bool {
            return false;
        }

        pub fn getValidity(self: *T, frame: *Frame) !*ValidityState {
            if (self._validity) |v| return v;
            const v = try frame._factory.create(ValidityState{ ._owner = self.asElement() });
            self._validity = v;
            return v;
        }

        pub fn getValidationMessage(_: *const T) []const u8 {
            return "";
        }

        pub fn checkValidity(_: *T) bool {
            return true;
        }

        pub fn reportValidity(_: *T) bool {
            return true;
        }

        pub fn setCustomValidity(self: *T, message: []const u8, frame: *Frame) !void {
            if (message.len == 0) {
                self._custom_validity = null;
            } else {
                self._custom_validity = try frame.dupeString(message);
            }
        }

        pub fn hasCustomValidity(self: *const T) bool {
            return self._custom_validity != null;
        }
    };
}
