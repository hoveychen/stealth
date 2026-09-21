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

const Values = std.StaticStringMap([]const u8);

/// Chrome's UA stylesheet for the SVG namespace, which is a DIFFERENT sheet
/// from the HTML one `chrome_per_tag_values` is generated from -- an element
/// named `text` in the HTML namespace is an unknown tag and takes none of
/// this.
///
/// Measured on a headed Chrome 153 over 32 SVG tag names by 32 property names
/// (scratch/s69/expr-svg-ua.js), diffed against a `<div>`. Only three kinds of
/// row came back:
///
///   * `unicode-bidi: normal`, which every one of the 32 has and which the
///     `unknown_tag` row already answers, since no SVG name is a key of the
///     HTML table;
///   * `display: inline` and `overflow: hidden`, which the layout resolves for
///     itself -- `display` is deliberately never stored in a table (see
///     `chrome_per_tag_values`), and `<svg>` is the one name here the HTML
///     table has a row for anyway;
///   * `white-space: nowrap` on `<text>` alone, which is this table.
///
/// The width that rule buys is the point of it. An SVG `<text>` measures on
/// the LAYOUT surface, spaces and all, and this is the declaration that says
/// so; `text_measure.svgWidth` carries the reading.
pub const per_tag = std.StaticStringMap(Values).initComptime(.{
    .{ "text", Values.initComptime(.{
        .{ "text-wrap", "nowrap" },
        .{ "text-wrap-mode", "nowrap" },
        .{ "unicode-bidi", "normal" },
        .{ "white-space", "nowrap" },
    }) },
});
