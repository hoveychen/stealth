// A module a paint worklet can load. The page cannot observe anything this
// leaves behind -- a worklet global is not the page's realm -- so the only
// thing under test is that fetching and compiling it succeeds.
globalThis.__paint_worklet_module_ran = true;
