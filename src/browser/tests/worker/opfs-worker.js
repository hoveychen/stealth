// The origin private file system, walked the way the Turnstile widget walks it
// inside its blob worker: getDirectory -> getFileHandle({create:true}) ->
// createSyncAccessHandle -> write -> time a flush -> close.
//
// Replies with { ok: true, results: {...} } or { ok: false, err }.
onmessage = async function() {
  try {
    const gates = {
      has_storage: typeof navigator.storage === 'object',
      // The feature detect the widget itself runs before it posts the probe.
      has_get_directory: !!(navigator.storage && navigator.storage.getDirectory),
      // [Exposed=(Window,Worker)] interfaces, all five of them reachable by
      // name from a dedicated worker in Chrome.
      handle_global: typeof FileSystemHandle,
      file_handle_global: typeof FileSystemFileHandle,
      directory_handle_global: typeof FileSystemDirectoryHandle,
      sync_handle_global: typeof FileSystemSyncAccessHandle,
      writable_global: typeof FileSystemWritableFileStream,
    };

    const root = await navigator.storage.getDirectory();
    const root_facts = {
      kind: root.kind,
      name: root.name,
      brand: Object.prototype.toString.call(root),
      is_directory_handle: root instanceof FileSystemDirectoryHandle,
      is_handle: root instanceof FileSystemHandle,
      // A fresh wrapper per call, but the same entry underneath.
      fresh_wrapper: (await navigator.storage.getDirectory()) !== root,
      same_entry: root.isSameEntry(await navigator.storage.getDirectory()),
    };

    const file = await root.getFileHandle('Itvrd0', { create: true });
    const file_facts = {
      kind: file.kind,
      name: file.name,
      brand: Object.prototype.toString.call(file),
      is_file_handle: file instanceof FileSystemFileHandle,
      same_entry: file.isSameEntry(await root.getFileHandle('Itvrd0')),
      // A file is not the directory that holds it.
      not_root: file.isSameEntry(root),
    };

    const handle = await file.createSyncAccessHandle();
    const written = handle.write(new Uint8Array([7, 8, 9]), { at: 0 });
    const size_after_write = handle.getSize();

    const started = performance.now();
    handle.flush();
    const flush_ms = performance.now() - started;

    // Read the three bytes back out through the same handle.
    const read_into = new Uint8Array(3);
    const read = handle.read(read_into, { at: 0 });

    handle.truncate(1);
    const size_after_truncate = handle.getSize();
    handle.close();

    // Closed is closed: every operation on it throws InvalidStateError.
    let after_close = null;
    try {
      handle.getSize();
    } catch (e) {
      after_close = e.name;
    }

    // The write survived the handle that made it.
    const reopened = await file.createSyncAccessHandle();
    const size_on_reopen = reopened.getSize();
    reopened.close();

    self.postMessage({
      ok: true,
      results: {
        gates: gates,
        root: root_facts,
        file: file_facts,
        sync: {
          brand: Object.prototype.toString.call(handle),
          is_sync_handle: handle instanceof FileSystemSyncAccessHandle,
          written: written,
          size_after_write: size_after_write,
          flush_is_number: typeof flush_ms === 'number',
          flush_is_finite: isFinite(flush_ms),
          // A timed flush that costs exactly nothing is the tell this plan
          // exists to close; see FileSystemSyncAccessHandle.flush.
          flush_is_positive: flush_ms > 0,
          flush_under_5ms: flush_ms < 5,
          read: read,
          read_bytes: Array.from(read_into),
          size_after_truncate: size_after_truncate,
          after_close: after_close,
          size_on_reopen: size_on_reopen,
        },
      },
    });
  } catch (e) {
    self.postMessage({ ok: false, err: (e && (e.name + ': ' + e.message)) || String(e) });
  }
};
