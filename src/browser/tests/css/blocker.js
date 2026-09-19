// A parser-blocking <script src> with nothing in it. Its point is the pause:
// the parser stops here and waits for the network, which is where a browser
// resolves the style it has so far and asks for what that style names.
globalThis.__blockerRan = true;
