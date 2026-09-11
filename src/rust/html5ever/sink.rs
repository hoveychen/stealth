// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

use std::ptr;
use std::cell::{Cell, RefCell};
use std::borrow::Cow;
use std::os::raw::c_void;

use crate::types::*;

use html5ever::interface::tree_builder::{ElementFlags, NodeOrText, QuirksMode, TreeSink};
use html5ever::tendril::StrTendril;
use html5ever::{Attribute, QualName};

type Arena<'arena> = &'arena typed_arena::Arena<ElementData>;

// Made public so it can be used from lib.rs
pub struct ElementData {
    pub qname: QualName,
    pub mathml_annotation_xml_integration_point: bool,
}
impl ElementData {
    fn new(qname: QualName, flags: ElementFlags) -> Self {
        Self {
            qname: qname,
            mathml_annotation_xml_integration_point: flags.mathml_annotation_xml_integration_point,
        }
    }
}

pub struct Sink<'arena> {
    pub ctx: Ref,
    pub document: Ref,
    pub arena: Arena<'arena>,
    pub quirks_mode: Cell<QuirksMode>,
    pub pop_callback: PopCallback,
    pub append_callback: AppendCallback,
    pub get_data_callback: GetDataCallback,
    pub parse_error_callback: ParseErrorCallback,
    pub create_element_callback: CreateElementCallback,
    pub create_comment_callback: CreateCommentCallback,
    pub create_processing_instruction: CreateProcessingInstruction,
    pub append_doctype_to_document: AppendDoctypeToDocumentCallback,
    pub add_attrs_if_missing_callback: AddAttrsIfMissingCallback,
    pub get_template_contents_callback: GetTemplateContentsCallback,
    pub remove_from_parent_callback: RemoveFromParentCallback,
    pub reparent_children_callback: ReparentChildrenCallback,
    pub append_before_sibling_callback: AppendBeforeSiblingCallback,
    pub append_based_on_parent_node_callback: AppendBasedOnParentNodeCallback,
    pub attach_declarative_shadow_callback: AttachDeclarativeShadowCallback,
    pub allow_declarative_shadow: bool,
    // xml5ever's tree builder consumes `xmlns` / `xmlns:*` attributes while
    // resolving namespaces and hands `create_element` a list with them already
    // stripped, but a browser keeps them in `element.attributes`. The XML
    // pipeline in lib.rs puts them here from a token sink that runs before the
    // tree builder, and `create_element` below puts them back. Always `None` on
    // the HTML path, which has no such stripping.
    pub namespace_declarations: RefCell<Option<Vec<Attribute>>>,
    // Set by `parse_error` when the tokenizer reports the `<?` that sends it
    // into the bogus comment state, and consumed by the `create_comment` that
    // follows. See `split_processing_instruction` for why the provenance is
    // needed: `<?pi foo?>` and `<!--?pi foo?-->` hand the sink the same text,
    // and Chrome makes a ProcessingInstruction out of only the first.
    pub bogus_comment_from_question_mark: Cell<bool>,
}

// html5ever 0.39's tokenizer, on `<?`, calls `bad_char_error()` and then
// reconsumes the `?` into the bogus comment state, which runs to the next `>`
// with nothing else emitted in between. With the default `ParseOpts` the error
// text is built by `format!("Saw {c} in state {state:?}")`.
const QUESTION_MARK_IN_TAG_OPEN: &str = "Saw ? in state TagOpen";

// Chrome 151 builds a ProcessingInstruction where the spec asks for a bogus
// comment. Measured against headed Chrome over ~25 shapes; `txt` is the bogus
// comment's text, which for `<?` still carries the leading `?`.
//
// The target runs to the first whitespace or `?`; a whitespace terminator is
// swallowed, a `?` is not. One trailing `?` comes off the data. The target is
// ASCII-lowercased and must look like [A-Za-z_][A-Za-z0-9_-]*, and Chrome
// refuses `xml` and anything starting with `xml-` (it takes `xmlfoo`).
fn split_processing_instruction(txt: &str) -> Option<(String, String)> {
    let rest = txt.strip_prefix('?')?;

    let end = rest
        .find(|c: char| c.is_ascii_whitespace() || c == '?')
        .unwrap_or(rest.len());
    let target = rest[..end].to_ascii_lowercase();

    let first = target.chars().next()?;
    if !(first.is_ascii_alphabetic() || first == '_') {
        return None;
    }
    if !target
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    {
        return None;
    }
    if target == "xml" || target.starts_with("xml-") {
        return None;
    }

    let after = if rest[end..].starts_with(|c: char| c.is_ascii_whitespace()) {
        &rest[end + 1..]
    } else {
        &rest[end..]
    };
    let data = after.strip_suffix('?').unwrap_or(after);

    Some((target, data.to_string()))
}

impl<'arena> TreeSink for Sink<'arena> {
    type Handle = *const c_void;
    type Output = ();
    type ElemName<'a>
        = &'a QualName
    where
        Self: 'a;

    fn finish(self) -> () {
        return ();
    }

    fn parse_error(&self, err: Cow<'static, str>) {
        if err == QUESTION_MARK_IN_TAG_OPEN {
            self.bogus_comment_from_question_mark.set(true);
        }
        unsafe {
            (self.parse_error_callback)(
                self.ctx,
                StringSlice {
                    ptr: err.as_ptr(),
                    len: err.len(),
                },
            );
        }
    }

    fn get_document(&self) -> *const c_void {
        return self.document;
    }

    fn set_quirks_mode(&self, mode: QuirksMode) {
        self.quirks_mode.set(mode);
    }

    fn same_node(&self, x: &Ref, y: &Ref) -> bool {
        ptr::eq::<c_void>(*x, *y)
    }

    fn elem_name(&self, target: &Ref) -> Self::ElemName<'_> {
        let opaque = unsafe { (self.get_data_callback)(*target) };
        let data = opaque as *mut ElementData;
        return unsafe { &(*data).qname };
    }

    fn get_template_contents(&self, target: &Ref) -> Ref {
        unsafe {
            return (self.get_template_contents_callback)(self.ctx, *target);
        }
    }

    fn is_mathml_annotation_xml_integration_point(&self, target: &Ref) -> bool {
        let opaque = unsafe { (self.get_data_callback)(*target) };
        let data = opaque as *mut ElementData;
        return unsafe { (*data).mathml_annotation_xml_integration_point };
    }

    fn pop(&self, node: &Ref) {
        unsafe {
            (self.pop_callback)(self.ctx, *node);
        }
    }

    fn create_element(&self, name: QualName, attrs: Vec<Attribute>, flags: ElementFlags) -> Ref {
        let data = self.arena.alloc(ElementData::new(name.clone(), flags));

        // A declaration comes first whatever its position in the source, which
        // is what Chrome reads back, and is what prepending gives us for free:
        // the tree builder passes the remaining attributes in source order.
        let attrs = match self.namespace_declarations.borrow_mut().take() {
            None => attrs,
            Some(mut declarations) => {
                declarations.extend(attrs);
                declarations
            }
        };

        unsafe {
            let mut attribute_iterator = CAttributeIterator { vec: attrs, pos: 0 };

            (self.create_element_callback)(
                self.ctx,
                data as *mut _ as *mut c_void,
                CQualName::create(&name),
                &mut attribute_iterator as *mut _ as *mut c_void,
            )
        }
    }

    fn create_comment(&self, txt: StrTendril) -> Ref {
        // Every comment clears the flag, so a `<?` that turned out not to name
        // a usable target cannot leak into the next one.
        if self.bogus_comment_from_question_mark.replace(false) {
            if let Some((target, data)) = split_processing_instruction(&txt) {
                return self.create_pi(StrTendril::from(target), StrTendril::from(data));
            }
        }
        let str = StringSlice{ ptr: txt.as_ptr(), len: txt.len()};
        unsafe {
            return (self.create_comment_callback)(self.ctx, str);
        }
    }

    fn create_pi(&self, target: StrTendril, data: StrTendril) -> Ref {
        let str_target = StringSlice {
            ptr: target.as_ptr(),
            len: target.len(),
        };
        let str_data = StringSlice {
            ptr: data.as_ptr(),
            len: data.len(),
        };
        unsafe {
            return (self.create_processing_instruction)(self.ctx, str_target, str_data);
        }
    }

    fn append(&self, parent: &Ref, child: NodeOrText<Ref>) {
        match child {
            NodeOrText::AppendText(ref t) => {
                // The child exists for the duration of the append_callback call,
                // but sometimes the memory on the Zig side, in append_callback,
                // is zeroed. If you try to refactor this code a bit, and do:
                //   unsafe {
                //       (self.append_callback)(self.ctx, *parent, CNodeOrText::create(child));
                //   }
                // Where CNodeOrText::create returns the property CNodeOrText,
                // you'll occasionally see that zeroed memory. Makes no sense to
                // me, but a far as I can tell, this version works.
                let byte_slice = t.as_ref().as_bytes();
                let static_slice: &'static [u8] = unsafe { std::mem::transmute(byte_slice) };
                unsafe {
                    (self.append_callback)(
                        self.ctx,
                        *parent,
                        CNodeOrText {
                            tag: 1,
                            node: ptr::null(),
                            text: StringSlice {
                                ptr: static_slice.as_ptr(),
                                len: static_slice.len(),
                            },
                        },
                    );
                };
            }
            NodeOrText::AppendNode(node) => {
                unsafe {
                    (self.append_callback)(
                        self.ctx,
                        *parent,
                        CNodeOrText {
                            tag: 0,
                            node: node,
                            text: StringSlice::default(),
                        },
                    );
                };
            }
        }
    }

    fn append_before_sibling(&self, sibling: &Ref, child: NodeOrText<Ref>) {
        match child {
            NodeOrText::AppendText(ref t) => {
                let byte_slice = t.as_ref().as_bytes();
                let static_slice: &'static [u8] = unsafe { std::mem::transmute(byte_slice) };
                unsafe {
                    (self.append_before_sibling_callback)(
                        self.ctx,
                        *sibling,
                        CNodeOrText {
                            tag: 1,
                            node: ptr::null(),
                            text: StringSlice {
                                ptr: static_slice.as_ptr(),
                                len: static_slice.len(),
                            },
                        },
                    );
                };
            }
            NodeOrText::AppendNode(node) => {
                unsafe {
                    (self.append_before_sibling_callback)(
                        self.ctx,
                        *sibling,
                        CNodeOrText {
                            tag: 0,
                            node: node,
                            text: StringSlice::default(),
                        },
                    );
                };
            }
        }
    }

    fn append_based_on_parent_node(
        &self,
        element: &Ref,
        prev_element: &Ref,
        child: NodeOrText<Ref>,
    ) {
        match child {
            NodeOrText::AppendText(ref t) => {
                let byte_slice = t.as_ref().as_bytes();
                let static_slice: &'static [u8] = unsafe { std::mem::transmute(byte_slice) };
                unsafe {
                    (self.append_based_on_parent_node_callback)(
                        self.ctx,
                        *element,
                        *prev_element,
                        CNodeOrText {
                            tag: 1,
                            node: ptr::null(),
                            text: StringSlice {
                                ptr: static_slice.as_ptr(),
                                len: static_slice.len(),
                            },
                        },
                    );
                };
            }
            NodeOrText::AppendNode(node) => {
                unsafe {
                    (self.append_based_on_parent_node_callback)(
                        self.ctx,
                        *element,
                        *prev_element,
                        CNodeOrText {
                            tag: 0,
                            node: node,
                            text: StringSlice::default(),
                        },
                    );
                };
            }
        }
    }

    fn append_doctype_to_document(
        &self,
        name: StrTendril,
        public_id: StrTendril,
        system_id: StrTendril,
    ) {
        let name_str = StringSlice {
            ptr: name.as_ptr(),
            len: name.len(),
        };
        let public_id_str = StringSlice {
            ptr: public_id.as_ptr(),
            len: public_id.len(),
        };
        let system_id_str = StringSlice {
            ptr: system_id.as_ptr(),
            len: system_id.len(),
        };
        unsafe {
            (self.append_doctype_to_document)(self.ctx, name_str, public_id_str, system_id_str);
        }
    }

    fn add_attrs_if_missing(&self, target: &Ref, attrs: Vec<Attribute>) {
        unsafe {
            let mut attribute_iterator = CAttributeIterator { vec: attrs, pos: 0 };

            (self.add_attrs_if_missing_callback)(
                self.ctx,
                *target,
                &mut attribute_iterator as *mut _ as *mut c_void,
            );
        }
    }

    fn remove_from_parent(&self, target: &Ref) {
        unsafe {
            (self.remove_from_parent_callback)(self.ctx, *target);
        }
    }

    fn reparent_children(&self, node: &Ref, new_parent: &Ref) {
        unsafe {
            (self.reparent_children_callback)(self.ctx, *node, *new_parent);
        }
    }

    fn allow_declarative_shadow_roots(&self, _intended_parent: &Ref) -> bool {
        self.allow_declarative_shadow
    }

    fn attach_declarative_shadow(
        &self,
        location: &Ref,
        template: &Ref,
        attrs: &[Attribute],
    ) -> bool {
        // html5ever only calls this when shadowrootmode is "open" or "closed",
        // so anything other than "open" is treated as "closed".
        let mode_is_open = attrs
            .iter()
            .find(|a| a.name.local.as_ref() == "shadowrootmode")
            .map(|a| a.value.as_ref() == "open")
            .unwrap_or(true);
        unsafe {
            (self.attach_declarative_shadow_callback)(
                self.ctx,
                *location,
                *template,
                if mode_is_open { 1 } else { 0 },
            ) != 0
        }
    }
}
