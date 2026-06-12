import 'dart:ui_web' as ui_web;

/// Web: only WebKit renders the IME's own marked-text underline visibly in
/// the engine's transparent hidden input (Blink derives the underline from
/// the transparent text color). Same detection the engine itself uses for
/// its Safari text-editing strategy (`ui_web.browser.browserEngine`).
bool get nativeComposingUnderline =>
    ui_web.browser.browserEngine == ui_web.BrowserEngine.webkit;
