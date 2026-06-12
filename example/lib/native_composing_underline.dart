/// Whether the host browser visibly decorates marked text in the Flutter
/// engine's hidden input — the app-side wiring for
/// `BulletEditor.nativeComposingUnderline` (browser detection deliberately
/// lives in the app, never inside the package).
///
/// WebKit paints the platform IME's marked-text underlines (per-clause
/// thick/thin, blue active clause) with their own colors, untouched by the
/// `color: transparent` the engine sets on the hidden element; Blink
/// derives its composition underline from the (transparent) text color, so
/// nothing shows there. Non-web platforms have no hidden DOM input at all.
library;

export 'native_composing_underline_stub.dart'
    if (dart.library.ui_web) 'native_composing_underline_web.dart';
