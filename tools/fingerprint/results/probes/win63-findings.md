# Batch 20 findings — G17's last window keys

Probes: `probe-win63.js` (P1 scope), `probe-win64.js` (P2/P4 gaps),
`probe-win65.js` (recognition lifecycle), `probe-win66.js` (coercion +
filesystem), `probe-win67.js` (data-URI encoding + Entry family), plus two
one-off FileWriter runs. Snapshots `win63-chrome.json` … `win67-chrome.json`.
Headed Chrome 150 over `http://localhost:8731/` (secure origin).

## Scope: 15 → 13. Two of the targets do not exist on Chrome 150.

| key | Chrome 150 | verdict |
|---|---|---|
| `openDatabase` | **ABSENT** (`ReferenceError`) | **do not add** — WebSQL removed |
| `MutationEvent` | **ABSENT** (`ReferenceError`) | **do not add** — removed |

`document.createEvent('MutationEvent')` also throws
`NotSupportedError: ... The provided event type ('MutationEvent') is invalid.`
Both are in CreepJS's Chrome-115-era table and Chrome has since dropped them.
Adding them would ship a global the reference browser does not have — the same
false signal batch 19 avoided with `ManagedMediaSource`. **CreepJS will keep
counting these two as "missing" forever; that is a scoring artefact, not a
defect. The floor for G17's window key gap is therefore 2, not 0.**

## Seven of the remaining thirteen are pure aliases

Every one of these is the **same constructor object** as an unprefixed name
(`===` is true, all measured):

| prefixed | is | engine has the target? |
|---|---|---|
| `webkitSpeechRecognition` | `SpeechRecognition` | now yes (batch 20 P2) |
| `webkitSpeechGrammar` | `SpeechGrammar` | now yes |
| `webkitSpeechGrammarList` | `SpeechGrammarList` | now yes |
| `webkitSpeechRecognitionEvent` | `SpeechRecognitionEvent` | now yes |
| `webkitSpeechRecognitionError` | **`SpeechRecognitionErrorEvent`** | now yes |
| `WebKitCSSMatrix` | `DOMMatrix` | yes (`DOMMatrixReadOnly.zig`) |
| `WebKitMutationObserver` | `MutationObserver` | yes (`MutationObserver.zig`) |

Note the fifth row: the prefixed name aliases an interface with a *different*
name.

## Speech Recognition (P2) — DONE

Shipped in `src/browser/webapi/speech/recognition.zig`, tests in
`src/browser/tests/speech_recognition.html`.

**Correction to the original P1 note:** `addFromURI` "not existing" was a
**probe bug** — the probe used that casing, Chrome's member is **`addFromUri`**
and the `protoOwn` capture in `win63-chrome.json` listed it all along. It exists,
arity 1, weight defaults to 1, and the URI is resolved against the document base
(`addFromUri(7)` reads back `http://localhost:8731/7`).

Everything else measured and reproduced:

- `SpeechRecognitionAlternative` / `Result` / `ResultList` are **not** globals.
  `SpeechRecognitionPhrase` **is** (Chrome 150, not in CreepJS's table) — shipped.
- `SpeechRecognition` has two statics, `available` and `install`, arity 1 each.
  `available({langs})` → `"available"`; with `processLocally: true` →
  `"downloadable"` (no on-device model installed).
- `quality` is `"command"` and its setter **does not take** — `'accurate'` and
  `'nope'` both bounce off.
- `phrases` is a plain Array, not frozen, and **identity-stable**
  (`rec.phrases === rec.phrases`). Assigning a non-sequence is a TypeError.
- `grammars = null` is a TypeError, not a clear.
- `maxAlternatives` is `unsigned long`: `-1` → 4294967295, `2.7` → 2, `NaN` → 0.
- `weight` is a restricted `float`: NaN is
  `"The provided float value is non-finite."`
- `addFromString` wraps its argument in `data:application/xml,` with a
  percent-encoding keep-set measured character by character over printable
  ASCII: unreserved (`A-Za-z0-9-._~`) plus `!`, `(`, `)`, `*`, `/`. That is
  neither `encodeURI`'s nor `encodeURIComponent`'s — `'` is escaped where
  encodeURIComponent keeps it, `/` is kept where it escapes it.
- **Lifecycle** (probe-win65): `start()` returns undefined and ~50ms later fires
  `error` (`not-allowed`) then `end`; a second `start()` while running is
  `InvalidStateError: Failed to execute 'start' on 'SpeechRecognition':
  recognition has already started.`; after the pair it can be started again;
  `stop()` or `abort()` in the same task pre-empts the failure and emits a lone
  `end`; `stop()`/`abort()` on an idle object emit nothing.
- `rec.onend = 5` reads back **null** — an IDL EventHandler takes anything.

## Filesystem (P3) — DONE

Shipped in `src/browser/webapi/filesystem.zig`, tests in
`src/browser/tests/filesystem.html`.

- `window.TEMPORARY === 0`, `PERSISTENT === 1`, and they live on
  **`Window.prototype`**, whose own keys on Chrome are exactly
  `TEMPORARY PERSISTENT constructor`. `Object.getOwnPropertyDescriptor(window,
  'TEMPORARY')` is `undefined` there.
- `webkitRequestFileSystem` / `webkitResolveLocalFileSystemURL` are
  **enumerable** own properties of the global (`ecw`), unlike interface objects.
- The call succeeds: `[object DOMFileSystem]`, `name` =
  `http_localhost_8731:Temporary` (origin with `:`/`/`/`.` collapsed to `_`,
  consecutive punctuation squashed, then `:Temporary`/`:Persistent`).
- **None** of `DOMFileSystem`, `Entry`, `DirectoryEntry`, `FileEntry`,
  `DirectoryReader`, `Metadata`, `FileWriter`, or any `FileSystem*` name is a
  global. Brands are not the WebIDL names.
- Prototype chain: `DirectoryEntry`/`FileEntry` → `Entry` → Object.prototype.
  `Entry`: `isFile isDirectory name fullPath filesystem copyTo/1 getMetadata/1
  getParent/0 moveTo/1 remove/1 toURL/0`. `DirectoryEntry`: `createReader/0
  getDirectory/1 getFile/1 removeRecursively/1`. `FileEntry`: `createWriter/1
  file/1`. `DirectoryReader`: `readEntries/1`. `Metadata`: `modificationTime
  size` (modificationTime is a `Date`).
- Errors: missing → `NotFoundError`; `exclusive` on an existing entry →
  `InvalidModificationError: An attempt was made to create a file or directory
  where an element already exists.`; wrong kind → `TypeMismatchError`; root
  `remove()` and a bad quota type → `InvalidModificationError: The object can
  not be modified in this way.`; another origin → `SecurityError`; a
  non-`filesystem:` URL → `EncodingError`.
- Entries are **fresh wrappers** per lookup (`getFile` twice → `!==`).
- `file()` hands back a real `File` whose `type` comes from the extension
  (`.txt` → `text/plain`).
- `FileWriter` (EventTarget): `readyState error position length` +
  six handlers + `INIT/WRITING/DONE` + `abort/0 seek/1 truncate/1 write/1`.
  `write(blob)` flips readyState to WRITING synchronously, then a task later
  fires `writestart` (position/length still old), **two** `progress` events
  (already final), `write`, `writeend`. `seek(-1)` counts from the end.
  A non-Blob is `parameter 1 is not of type 'Blob'.`

## Misc (P4) — DONE

Shipped in `element/html/FrameElement.zig`, `element/html/Menu.zig`,
`canvas/ImageBitmapRenderingContext.zig`, plus `constructor_aliases` on
`DOMMatrix` and `MutationObserver`. Tests in
`src/browser/tests/legacy_misc.html`.

- `HTMLFrameElement` ← `<frame>`: `name scrolling src frameBorder longDesc
  noResize contentDocument contentWindow marginHeight marginWidth`. All ""/false
  by default, `contentDocument`/`contentWindow` null and getter-only, `src`
  resolves against the base.
- `HTMLMenuElement` ← `<menu>`: `compact` only.
- `ImageBitmapRenderingContext` ← `canvas.getContext('bitmaprenderer')`:
  `canvas` (getter-only) + `transferFromImageBitmap/1`. Returns undefined,
  consumes the bitmap (source reads 0x0 afterwards), does **not** resize the
  canvas. `null` is accepted; anything else is
  `parameter 1 is not of type 'ImageBitmap'.`
- Wiring `WebKitMutationObserver` exposed two MutationObserver gaps, both fixed:
  prototype order was `observe disconnect takeRecords` where Chrome has
  `disconnect observe takeRecords`, and the constructor reported arity 0 where
  Chrome reports 1.

### ElementInternals — DONE

Shipped in `src/browser/webapi/element/ElementInternals.zig` (plus
`attachInternals()` on `element/Html.zig`, a real `CustomStateSet`, a `:state()`
selector, `ValidityState.Flags`, `Form.ownerOf` and a second pass in
`FormData.collectForm`). Tests in `src/browser/tests/element/element_internals.html`.
The measurements below are what it was built from.

Full table in `win64-chrome.json` under `internals`, measured through a
**form-associated** custom element (`static formAssociated = true`) inside a
`<form>`:

- 63 prototype members in this order: `form willValidate validity
  validationMessage labels states shadowRoot role` then 41 `aria*` accessors,
  then `checkValidity/0 reportValidity/0 setFormValue/1 setValidity/1`, then
  `ariaColIndexText ariaRowIndexText ariaActiveDescendantElement
  ariaControlsElements ariaDescribedByElements ariaDetailsElements
  ariaErrorMessageElements ariaFlowToElements ariaLabelledByElements`.
  The first seven are getter-only; `role` and every `aria*` is read/write.
  (The exact order is in `win64-chrome.json` → `shapes.ElementInternals.protoOwn`.)
- `form` → the enclosing `HTMLFormElement`; on a **non**-form-associated custom
  element reading it is `NotSupportedError: Failed to read the 'form' property
  from 'ElementInternals': The target element is not a form-associated custom
  element.`
- `willValidate` true, `validity` `[object ValidityState]` (`valid` true),
  `validationMessage` `""`, `labels` `[object NodeList]` len 0, `states`
  `[object CustomStateSet]` size 0, `shadowRoot` null.
- `checkValidity()` / `reportValidity()` → true.
- `setFormValue('v')` → undefined, and the value **does** show up in
  `new FormData(form)` under the element's `name`.
- `setValidity({})` → valid; `setValidity({customError: true}, 'bad')` → invalid,
  `validationMessage` `"bad"`, `checkValidity()` false; `setValidity({customError:
  true})` with no message → `TypeError: ... The second argument should not be
  empty if one or more flags in the first argument are true.`
- ARIA on internals is **separate storage**: `i.ariaLabel = 'hello'` reads back
  `'hello'`, `el.getAttribute('aria-label')` stays null, and `el.ariaLabel`
  still reads the attribute independently (`internals=hello|element=attr`).
  `i.ariaLabel = null` → null. `i.ariaLevel = 3` → `"3"` (a string).
  `i.ariaLabelledByElements = [form]` reads back an Array of length 1.
  `i.role = 'button'` → `'button'`, attribute stays null.
- `states.add('--on')` → size 1; `el.matches(':state(on)')` is false.
- `attachInternals()` twice → `NotSupportedError: ... ElementInternals for the
  specified element was already attached.`

## P5 verification

Field-by-field diff of `probe-win63` against `win63-chrome.json`: **548 paths, 7
differing.** Two are the harness's own origin (Chrome ran on `localhost:8731`,
lightpanda serves the probe page from an ephemeral port), five are the
engine-wide gaps below. CreepJS: window own keys 1146 -> 1165, window spans
18 -> 5, total spans 142 -> 129, window missing keys **15 -> 2** — the floor.
Full suite 1248/1248, `zig fmt --check` clean, `lightpanda serve` starts.

Four gaps the diff surfaced were **fixed** rather than recorded: DOMMatrix's
alphabetical operation and static order (WebKitCSSMatrix is the same object),
MutationRecord's member order, `MutationObserver.prototype.observe` arity 1, and
`createEvent` naming the type it refused.

## Engine gaps this batch surfaced but did NOT fix

Record them; they are engine-wide, not batch-20 defects.

1. `Object.getOwnPropertyDescriptor(SomeInterface, 'prototype')` throws
   `TypeError: Illegal invocation` for any interface whose instances carry an
   indexed or named interceptor — `FileList`, `MediaSource`, `SpeechSynthesis`
   all threw before this batch. It is why `expectInterfaceObject()` is unusable
   in `speech_recognition.html`.
2. `bridge.indexed` renders an indexed slot `writable:true, enumerable:false`
   where Chrome renders `writable:false, enumerable:true`. `FileList` reads the
   same way, before this batch.
3. The bespoke `?js.Function` handler accessors on `SpeechSynthesis` and
   `SpeechSynthesisUtterance` throw `TypeError: invalid argument` when assigned
   a non-callable; Chrome (and `window.onload`, `el.onclick`, `xhr.onload`,
   `signal.onabort` here) store null. `recognition.zig` and `filesystem.zig`
   use the `Window.FunctionSetter`-shaped union to get this right.
4. `new HTMLDivElement()` (and every other element interface) throws a
   `TypeError` with an **empty message**; Chrome says
   `Failed to construct 'HTMLDivElement': Illegal constructor`.
5. `new DOMMatrix('nope')` says `The string did not match the expected pattern`;
   Chrome says `Failed to construct 'DOMMatrix': Failed to parse 'nope'.`
5b. `constructor` always lands last on a prototype. Chrome puts a partial
   interface's members *after* it -- `DOMMatrix.prototype` ends
   `... translateSelf constructor setMatrixValue` because `setMatrixValue` comes
   from the legacy WebKitCSSMatrix partial. Same limitation as G14's.
5c. `internals.labels` is an Array where Chrome hands back a NodeList.
   `input.labels` reads the same way; it is how label lists are built here.
6. The bridge produces WebIDL's "N argument(s) required, but only M present."
   only for **constructors**. Operations get `invalid argument` unless the
   module reads the argument as `?js.Value` and throws by hand.
