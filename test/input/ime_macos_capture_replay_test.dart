import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ime_replay.dart';
import 'ime_service_test.dart' show FakeImeConnection;

/// REAL macOS desktop captures (delta frontend) of Korean 2-Set, Chinese
/// Pinyin, and Hindi Transliteration — happy-path sessions where the user
/// types a word and the IME commits it.
///
/// Korean is notable: the macOS IME sends NO composing range — each keystroke
/// is an insertion or replacement that reshapes the current syllable block,
/// committed implicitly when the next syllable's initial consonant arrives.
///
/// Chinese Pinyin carries a composing range over the full pinyin string until
/// the user presses Space to pick a candidate, at which point a replacement
/// commits the characters and clears composing.
///
/// Hindi Transliteration is similar to Pinyin — composing over the romanized
/// text, committed by Space or Enter into Devanagari.
void main() {
  late EditorController controller;
  late List<FakeImeConnection> connections;
  late ImeService service;

  void buildService() {
    controller = EditorController(
      document: Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('')],
        ),
      ]),
      schema: EditorSchema.standard(),
      undoGrouping: (previous, current) => false,
    );
    controller
        .setSelection(DocSelection.collapsed(const DocPosition('a', 0)));
    connections = [];
    service = ImeService(
      controller: controller,
      connectionFactory: (client, configuration) {
        final connection = FakeImeConnection();
        connections.add(connection);
        return connection;
      },
    );
    service.attach();
  }

  String blockText() => controller.document.allBlocks.last.plainText;

  // ---------------------------------------------------------------------------
  // Korean 2-Set: 안녕 (annyeong / hello)
  // Keys: d k s s u d
  // ---------------------------------------------------------------------------
  const koreanAnnyeong = r'''
{"seq":64,"ms":1331285,"kind":"attach","payload":{"frontend":"delta"}}
{"seq":65,"ms":1331285,"kind":"push","payload":{"text":". ","sel":[2,2],"composing":null,"viaTerminate":false}}
{"seq":66,"ms":1341699,"kind":"key","payload":{"kind":"down","key":"D","character":"ㅇ","deferred":false,"handler":"ignored"}}
{"seq":67,"ms":1341704,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". ","inserted":"ㅇ","at":2,"sel":[3,3],"composing":null}]}}
{"seq":68,"ms":1341801,"kind":"key","payload":{"kind":"up","key":"D","character":null,"deferred":false,"handler":"ignored"}}
{"seq":69,"ms":1341867,"kind":"key","payload":{"kind":"down","key":"K","character":"ㅏ","deferred":false,"handler":"ignored"}}
{"seq":70,"ms":1341872,"kind":"deltas","payload":{"deltas":[{"type":"replacement","oldText":". ㅇ","replaced":[2,3],"text":"아","sel":[3,3],"composing":null}]}}
{"seq":71,"ms":1341941,"kind":"key","payload":{"kind":"up","key":"K","character":null,"deferred":false,"handler":"ignored"}}
{"seq":72,"ms":1342171,"kind":"key","payload":{"kind":"down","key":"S","character":"ㄴ","deferred":false,"handler":"ignored"}}
{"seq":73,"ms":1342176,"kind":"deltas","payload":{"deltas":[{"type":"replacement","oldText":". 아","replaced":[2,3],"text":"안","sel":[3,3],"composing":null}]}}
{"seq":74,"ms":1342251,"kind":"key","payload":{"kind":"up","key":"S","character":null,"deferred":false,"handler":"ignored"}}
{"seq":75,"ms":1342372,"kind":"key","payload":{"kind":"down","key":"S","character":"ㄴ","deferred":false,"handler":"ignored"}}
{"seq":76,"ms":1342376,"kind":"deltas","payload":{"deltas":[{"type":"nonText","oldText":". 안","sel":[3,3],"composing":null}]}}
{"seq":77,"ms":1342378,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". 안","inserted":"ㄴ","at":3,"sel":[4,4],"composing":null}]}}
{"seq":78,"ms":1342451,"kind":"key","payload":{"kind":"up","key":"S","character":null,"deferred":false,"handler":"ignored"}}
{"seq":79,"ms":1343117,"kind":"key","payload":{"kind":"down","key":"U","character":"ㅕ","deferred":false,"handler":"ignored"}}
{"seq":80,"ms":1343121,"kind":"deltas","payload":{"deltas":[{"type":"replacement","oldText":". 안ㄴ","replaced":[3,4],"text":"녀","sel":[4,4],"composing":null}]}}
{"seq":81,"ms":1343196,"kind":"key","payload":{"kind":"up","key":"U","character":null,"deferred":false,"handler":"ignored"}}
{"seq":82,"ms":1343396,"kind":"key","payload":{"kind":"down","key":"D","character":"ㅇ","deferred":false,"handler":"ignored"}}
{"seq":83,"ms":1343399,"kind":"deltas","payload":{"deltas":[{"type":"replacement","oldText":". 안녀","replaced":[3,4],"text":"녕","sel":[4,4],"composing":null}]}}
{"seq":84,"ms":1343483,"kind":"key","payload":{"kind":"up","key":"D","character":null,"deferred":false,"handler":"ignored"}}
''';

  test('Korean 2-Set: 안녕 (annyeong) — jamo compose into syllable blocks '
      'without composing range', () {
    buildService();
    replayImeJournal(service, parseImeJournalDump(koreanAnnyeong));

    expect(blockText(), '안녕');
    expect(controller.composing, isNull);
    expect(service.currentTextEditingValue!.composing, TextRange.empty);
    expect(controller.selection!.isCollapsed, isTrue);

    final journal = service.journal.toJson();
    expect(
      journal.where((e) => e['kind'] == 'terminate'),
      isEmpty,
      reason: 'no composition was live, so nothing to terminate',
    );
  });

  // ---------------------------------------------------------------------------
  // Korean 2-Set: 한글 (hangul / Korean script)
  // Keys: g k s r m f
  // ---------------------------------------------------------------------------
  const koreanHangul = r'''
{"seq":100,"ms":1371361,"kind":"attach","payload":{"frontend":"delta"}}
{"seq":101,"ms":1371361,"kind":"push","payload":{"text":". ","sel":[2,2],"composing":null,"viaTerminate":false}}
{"seq":102,"ms":1374233,"kind":"key","payload":{"kind":"down","key":"G","character":"ㅎ","deferred":false,"handler":"ignored"}}
{"seq":103,"ms":1374237,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". ","inserted":"ㅎ","at":2,"sel":[3,3],"composing":null}]}}
{"seq":104,"ms":1374320,"kind":"key","payload":{"kind":"up","key":"G","character":null,"deferred":false,"handler":"ignored"}}
{"seq":105,"ms":1374565,"kind":"key","payload":{"kind":"down","key":"K","character":"ㅏ","deferred":false,"handler":"ignored"}}
{"seq":106,"ms":1374571,"kind":"deltas","payload":{"deltas":[{"type":"replacement","oldText":". ㅎ","replaced":[2,3],"text":"하","sel":[3,3],"composing":null}]}}
{"seq":107,"ms":1374639,"kind":"key","payload":{"kind":"up","key":"K","character":null,"deferred":false,"handler":"ignored"}}
{"seq":108,"ms":1375724,"kind":"key","payload":{"kind":"down","key":"S","character":"ㄴ","deferred":false,"handler":"ignored"}}
{"seq":109,"ms":1375729,"kind":"deltas","payload":{"deltas":[{"type":"replacement","oldText":". 하","replaced":[2,3],"text":"한","sel":[3,3],"composing":null}]}}
{"seq":110,"ms":1375802,"kind":"key","payload":{"kind":"up","key":"S","character":null,"deferred":false,"handler":"ignored"}}
{"seq":111,"ms":1376673,"kind":"key","payload":{"kind":"down","key":"R","character":"ㄱ","deferred":false,"handler":"ignored"}}
{"seq":112,"ms":1376678,"kind":"deltas","payload":{"deltas":[{"type":"nonText","oldText":". 한","sel":[3,3],"composing":null}]}}
{"seq":113,"ms":1376681,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". 한","inserted":"ㄱ","at":3,"sel":[4,4],"composing":null}]}}
{"seq":114,"ms":1376761,"kind":"key","payload":{"kind":"up","key":"R","character":null,"deferred":false,"handler":"ignored"}}
{"seq":115,"ms":1377283,"kind":"key","payload":{"kind":"down","key":"M","character":"ㅡ","deferred":false,"handler":"ignored"}}
{"seq":116,"ms":1377288,"kind":"deltas","payload":{"deltas":[{"type":"replacement","oldText":". 한ㄱ","replaced":[3,4],"text":"그","sel":[4,4],"composing":null}]}}
{"seq":117,"ms":1377368,"kind":"key","payload":{"kind":"up","key":"M","character":null,"deferred":false,"handler":"ignored"}}
{"seq":118,"ms":1377748,"kind":"key","payload":{"kind":"down","key":"F","character":"ㄹ","deferred":false,"handler":"ignored"}}
{"seq":119,"ms":1377753,"kind":"deltas","payload":{"deltas":[{"type":"replacement","oldText":". 한그","replaced":[3,4],"text":"글","sel":[4,4],"composing":null}]}}
{"seq":120,"ms":1377840,"kind":"key","payload":{"kind":"up","key":"F","character":null,"deferred":false,"handler":"ignored"}}
''';

  test('Korean 2-Set: 한글 (hangul) — syllable-boundary nonText+insertion '
      'splits correctly', () {
    buildService();
    replayImeJournal(service, parseImeJournalDump(koreanHangul));

    expect(blockText(), '한글');
    expect(controller.composing, isNull);
    expect(controller.selection!.isCollapsed, isTrue);

    final journal = service.journal.toJson();
    expect(
      journal.where((e) => e['kind'] == 'terminate'),
      isEmpty,
    );
  });

  // ---------------------------------------------------------------------------
  // Chinese Pinyin: 你好 (nihao)
  // Keys: n i h a o Space
  // ---------------------------------------------------------------------------
  const chineseNihao = r'''
{"seq":139,"ms":1400359,"kind":"attach","payload":{"frontend":"delta"}}
{"seq":140,"ms":1400359,"kind":"push","payload":{"text":". ","sel":[2,2],"composing":null,"viaTerminate":false}}
{"seq":141,"ms":1402224,"kind":"key","payload":{"kind":"down","key":"N","character":"n","deferred":false,"handler":"ignored"}}
{"seq":142,"ms":1402260,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". ","inserted":"n","at":2,"sel":[3,3],"composing":[2,3]}]}}
{"seq":143,"ms":1402324,"kind":"key","payload":{"kind":"up","key":"N","character":null,"deferred":false,"handler":"ignored"}}
{"seq":144,"ms":1402436,"kind":"key","payload":{"kind":"down","key":"I","character":"i","deferred":true,"handler":"ignored"}}
{"seq":145,"ms":1402441,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". n","inserted":"i","at":3,"sel":[4,4],"composing":[2,4]}]}}
{"seq":146,"ms":1402541,"kind":"key","payload":{"kind":"up","key":"I","character":null,"deferred":false,"handler":"ignored"}}
{"seq":147,"ms":1402717,"kind":"key","payload":{"kind":"down","key":"H","character":"h","deferred":true,"handler":"ignored"}}
{"seq":148,"ms":1402737,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". ni","inserted":" h","at":4,"sel":[6,6],"composing":[2,6]}]}}
{"seq":149,"ms":1402830,"kind":"key","payload":{"kind":"up","key":"H","character":null,"deferred":false,"handler":"ignored"}}
{"seq":150,"ms":1403010,"kind":"key","payload":{"kind":"down","key":"A","character":"a","deferred":true,"handler":"ignored"}}
{"seq":151,"ms":1403020,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". ni h","inserted":"a","at":6,"sel":[7,7],"composing":[2,7]}]}}
{"seq":152,"ms":1403110,"kind":"key","payload":{"kind":"up","key":"A","character":null,"deferred":false,"handler":"ignored"}}
{"seq":153,"ms":1403574,"kind":"key","payload":{"kind":"down","key":"O","character":"o","deferred":true,"handler":"ignored"}}
{"seq":154,"ms":1403585,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". ni ha","inserted":"o","at":7,"sel":[8,8],"composing":[2,8]}]}}
{"seq":155,"ms":1403663,"kind":"key","payload":{"kind":"up","key":"O","character":null,"deferred":false,"handler":"ignored"}}
{"seq":156,"ms":1404035,"kind":"key","payload":{"kind":"down","key":" ","character":" ","deferred":true,"handler":"ignored"}}
{"seq":157,"ms":1404039,"kind":"deltas","payload":{"deltas":[{"type":"replacement","oldText":". ni hao","replaced":[2,8],"text":"你好","sel":[4,4],"composing":null}]}}
{"seq":158,"ms":1404108,"kind":"key","payload":{"kind":"up","key":" ","character":null,"deferred":false,"handler":"ignored"}}
''';

  test('Chinese Pinyin: 你好 (nihao) — composing range covers full pinyin, '
      'Space commits', () {
    buildService();
    replayImeJournal(service, parseImeJournalDump(chineseNihao));

    expect(blockText(), '你好');
    expect(controller.composing, isNull);
    expect(service.currentTextEditingValue!.composing, TextRange.empty);
    expect(controller.selection!.isCollapsed, isTrue);

    final journal = service.journal.toJson();
    expect(
      journal.where((e) => e['kind'] == 'terminate'),
      isEmpty,
      reason: 'composition committed cleanly via Space',
    );
  });

  // ---------------------------------------------------------------------------
  // Chinese Pinyin: 中国 (zhongguo)
  // Keys: z h o n g g u o Space
  // ---------------------------------------------------------------------------
  const chineseZhongguo = r'''
{"seq":230,"ms":1435719,"kind":"key","payload":{"kind":"down","key":"Z","character":"z","deferred":false,"handler":"ignored"}}
{"seq":231,"ms":1435728,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". ","inserted":"z","at":2,"sel":[3,3],"composing":[2,3]}]}}
{"seq":232,"ms":1435817,"kind":"key","payload":{"kind":"down","key":"H","character":"h","deferred":true,"handler":"ignored"}}
{"seq":233,"ms":1435823,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". z","inserted":"h","at":3,"sel":[4,4],"composing":[2,4]}]}}
{"seq":234,"ms":1435830,"kind":"key","payload":{"kind":"up","key":"Z","character":null,"deferred":false,"handler":"ignored"}}
{"seq":235,"ms":1435895,"kind":"key","payload":{"kind":"up","key":"H","character":null,"deferred":false,"handler":"ignored"}}
{"seq":236,"ms":1436014,"kind":"key","payload":{"kind":"down","key":"O","character":"o","deferred":true,"handler":"ignored"}}
{"seq":237,"ms":1436019,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". zh","inserted":"o","at":4,"sel":[5,5],"composing":[2,5]}]}}
{"seq":238,"ms":1436113,"kind":"key","payload":{"kind":"up","key":"O","character":null,"deferred":false,"handler":"ignored"}}
{"seq":239,"ms":1436226,"kind":"key","payload":{"kind":"down","key":"N","character":"n","deferred":true,"handler":"ignored"}}
{"seq":240,"ms":1436229,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". zho","inserted":"n","at":5,"sel":[6,6],"composing":[2,6]}]}}
{"seq":241,"ms":1436293,"kind":"key","payload":{"kind":"up","key":"N","character":null,"deferred":false,"handler":"ignored"}}
{"seq":242,"ms":1436378,"kind":"key","payload":{"kind":"down","key":"G","character":"g","deferred":true,"handler":"ignored"}}
{"seq":243,"ms":1436380,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". zhon","inserted":"g","at":6,"sel":[7,7],"composing":[2,7]}]}}
{"seq":244,"ms":1436466,"kind":"key","payload":{"kind":"up","key":"G","character":null,"deferred":false,"handler":"ignored"}}
{"seq":245,"ms":1437431,"kind":"key","payload":{"kind":"down","key":"G","character":"g","deferred":true,"handler":"ignored"}}
{"seq":246,"ms":1437433,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". zhong","inserted":" g","at":7,"sel":[9,9],"composing":[2,9]}]}}
{"seq":247,"ms":1437515,"kind":"key","payload":{"kind":"up","key":"G","character":null,"deferred":false,"handler":"ignored"}}
{"seq":248,"ms":1437543,"kind":"key","payload":{"kind":"down","key":"U","character":"u","deferred":true,"handler":"ignored"}}
{"seq":249,"ms":1437546,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". zhong g","inserted":"u","at":9,"sel":[10,10],"composing":[2,10]}]}}
{"seq":250,"ms":1437627,"kind":"key","payload":{"kind":"up","key":"U","character":null,"deferred":false,"handler":"ignored"}}
{"seq":251,"ms":1437880,"kind":"key","payload":{"kind":"down","key":"O","character":"o","deferred":true,"handler":"ignored"}}
{"seq":252,"ms":1437884,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". zhong gu","inserted":"o","at":10,"sel":[11,11],"composing":[2,11]}]}}
{"seq":253,"ms":1437972,"kind":"key","payload":{"kind":"up","key":"O","character":null,"deferred":false,"handler":"ignored"}}
{"seq":254,"ms":1438453,"kind":"key","payload":{"kind":"down","key":" ","character":" ","deferred":true,"handler":"ignored"}}
{"seq":255,"ms":1438456,"kind":"deltas","payload":{"deltas":[{"type":"replacement","oldText":". zhong guo","replaced":[2,11],"text":"中国","sel":[4,4],"composing":null}]}}
{"seq":256,"ms":1438539,"kind":"key","payload":{"kind":"up","key":" ","character":null,"deferred":false,"handler":"ignored"}}
''';

  test('Chinese Pinyin: 中国 (zhongguo) — multi-syllable pinyin with space '
      'separator commits correctly', () {
    buildService();

    // This capture lacks an attach event — the session was mid-flight.
    // Manually push the initial window to match the capture's starting state.
    connections.last.pushed.clear();

    replayImeJournal(service, parseImeJournalDump(chineseZhongguo));

    expect(blockText(), '中国');
    expect(controller.composing, isNull);
    expect(service.currentTextEditingValue!.composing, TextRange.empty);
    expect(controller.selection!.isCollapsed, isTrue);
  });

  // ---------------------------------------------------------------------------
  // Hindi Transliteration: नमस्ते (namaste)
  // Keys: n a m a s t e Space
  // ---------------------------------------------------------------------------
  const hindiNamaste = r'''
{"seq":274,"ms":1513592,"kind":"key","payload":{"kind":"down","key":"N","character":"n","deferred":false,"handler":"ignored"}}
{"seq":275,"ms":1514036,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". ","inserted":"n","at":2,"sel":[3,3],"composing":[2,3]}]}}
{"seq":276,"ms":1514049,"kind":"key","payload":{"kind":"up","key":"N","character":null,"deferred":false,"handler":"ignored"}}
{"seq":277,"ms":1514645,"kind":"key","payload":{"kind":"down","key":"A","character":"a","deferred":true,"handler":"ignored"}}
{"seq":278,"ms":1514660,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". n","inserted":"a","at":3,"sel":[4,4],"composing":[2,4]}]}}
{"seq":279,"ms":1514729,"kind":"key","payload":{"kind":"up","key":"A","character":null,"deferred":false,"handler":"ignored"}}
{"seq":280,"ms":1514864,"kind":"key","payload":{"kind":"down","key":"M","character":"m","deferred":true,"handler":"ignored"}}
{"seq":281,"ms":1514878,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". na","inserted":"m","at":4,"sel":[5,5],"composing":[2,5]}]}}
{"seq":282,"ms":1514947,"kind":"key","payload":{"kind":"up","key":"M","character":null,"deferred":false,"handler":"ignored"}}
{"seq":283,"ms":1515072,"kind":"key","payload":{"kind":"down","key":"A","character":"a","deferred":true,"handler":"ignored"}}
{"seq":284,"ms":1515084,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". nam","inserted":"a","at":5,"sel":[6,6],"composing":[2,6]}]}}
{"seq":285,"ms":1515176,"kind":"key","payload":{"kind":"up","key":"A","character":null,"deferred":false,"handler":"ignored"}}
{"seq":286,"ms":1515360,"kind":"key","payload":{"kind":"down","key":"S","character":"s","deferred":true,"handler":"ignored"}}
{"seq":287,"ms":1515379,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". nama","inserted":"s","at":6,"sel":[7,7],"composing":[2,7]}]}}
{"seq":288,"ms":1515459,"kind":"key","payload":{"kind":"up","key":"S","character":null,"deferred":false,"handler":"ignored"}}
{"seq":289,"ms":1515624,"kind":"key","payload":{"kind":"down","key":"T","character":"t","deferred":true,"handler":"ignored"}}
{"seq":290,"ms":1515656,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". namas","inserted":"t","at":7,"sel":[8,8],"composing":[2,8]}]}}
{"seq":291,"ms":1515736,"kind":"key","payload":{"kind":"down","key":"E","character":"e","deferred":true,"handler":"ignored"}}
{"seq":292,"ms":1515759,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". namast","inserted":"e","at":8,"sel":[9,9],"composing":[2,9]}]}}
{"seq":293,"ms":1515780,"kind":"key","payload":{"kind":"up","key":"T","character":null,"deferred":false,"handler":"ignored"}}
{"seq":294,"ms":1515864,"kind":"key","payload":{"kind":"up","key":"E","character":null,"deferred":false,"handler":"ignored"}}
{"seq":295,"ms":1516497,"kind":"key","payload":{"kind":"down","key":" ","character":" ","deferred":true,"handler":"ignored"}}
{"seq":296,"ms":1516499,"kind":"deltas","payload":{"deltas":[{"type":"replacement","oldText":". namaste","replaced":[2,9],"text":"नमस्ते ","sel":[9,9],"composing":null}]}}
{"seq":297,"ms":1516588,"kind":"key","payload":{"kind":"up","key":" ","character":null,"deferred":false,"handler":"ignored"}}
''';

  test('Hindi Transliteration: नमस्ते (namaste) — romanized composing '
      'commits Devanagari on Space', () {
    buildService();
    connections.last.pushed.clear();

    replayImeJournal(service, parseImeJournalDump(hindiNamaste));

    // The IME commits "नमस्ते " (with trailing space).
    expect(blockText(), 'नमस्ते ');
    expect(controller.composing, isNull);
    expect(service.currentTextEditingValue!.composing, TextRange.empty);
    expect(controller.selection!.isCollapsed, isTrue);
  });

  // ---------------------------------------------------------------------------
  // Hindi Transliteration: हिंदी (hindi)
  // Keys: h i n d o Backspace i Enter
  // The user mistyped 'o', backspaced, typed 'i', then Enter to commit.
  // ---------------------------------------------------------------------------
  const hindiHindi = r'''
{"seq":334,"ms":1534221,"kind":"attach","payload":{"frontend":"delta"}}
{"seq":335,"ms":1534221,"kind":"push","payload":{"text":". ","sel":[2,2],"composing":null,"viaTerminate":false}}
{"seq":336,"ms":1534933,"kind":"key","payload":{"kind":"down","key":"Caps Lock","character":null,"deferred":false,"handler":"ignored"}}
{"seq":337,"ms":1534933,"kind":"key","payload":{"kind":"up","key":"Caps Lock","character":null,"deferred":false,"handler":"ignored"}}
{"seq":338,"ms":1534938,"kind":"key","payload":{"kind":"down","key":"Caps Lock","character":null,"deferred":false,"handler":"ignored"}}
{"seq":339,"ms":1534938,"kind":"key","payload":{"kind":"up","key":"Caps Lock","character":null,"deferred":false,"handler":"ignored"}}
{"seq":340,"ms":1536251,"kind":"key","payload":{"kind":"down","key":"H","character":"h","deferred":false,"handler":"ignored"}}
{"seq":341,"ms":1536279,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". ","inserted":"h","at":2,"sel":[3,3],"composing":[2,3]}]}}
{"seq":342,"ms":1536357,"kind":"key","payload":{"kind":"up","key":"H","character":null,"deferred":false,"handler":"ignored"}}
{"seq":343,"ms":1536519,"kind":"key","payload":{"kind":"down","key":"I","character":"i","deferred":true,"handler":"ignored"}}
{"seq":344,"ms":1536538,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". h","inserted":"i","at":3,"sel":[4,4],"composing":[2,4]}]}}
{"seq":345,"ms":1536594,"kind":"key","payload":{"kind":"up","key":"I","character":null,"deferred":false,"handler":"ignored"}}
{"seq":346,"ms":1536692,"kind":"key","payload":{"kind":"down","key":"N","character":"n","deferred":true,"handler":"ignored"}}
{"seq":347,"ms":1536706,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". hi","inserted":"n","at":4,"sel":[5,5],"composing":[2,5]}]}}
{"seq":348,"ms":1536759,"kind":"key","payload":{"kind":"up","key":"N","character":null,"deferred":false,"handler":"ignored"}}
{"seq":349,"ms":1536849,"kind":"key","payload":{"kind":"down","key":"D","character":"d","deferred":true,"handler":"ignored"}}
{"seq":350,"ms":1536864,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". hin","inserted":"d","at":5,"sel":[6,6],"composing":[2,6]}]}}
{"seq":351,"ms":1536925,"kind":"key","payload":{"kind":"up","key":"D","character":null,"deferred":false,"handler":"ignored"}}
{"seq":352,"ms":1537083,"kind":"key","payload":{"kind":"down","key":"O","character":"o","deferred":true,"handler":"ignored"}}
{"seq":353,"ms":1537116,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". hind","inserted":"o","at":6,"sel":[7,7],"composing":[2,7]}]}}
{"seq":354,"ms":1537167,"kind":"key","payload":{"kind":"up","key":"O","character":null,"deferred":false,"handler":"ignored"}}
{"seq":355,"ms":1537712,"kind":"key","payload":{"kind":"down","key":"Backspace","character":"","deferred":true,"handler":"ignored"}}
{"seq":356,"ms":1537732,"kind":"deltas","payload":{"deltas":[{"type":"deletion","oldText":". hindo","deleted":[6,7],"sel":[6,6],"composing":[2,6]}]}}
{"seq":357,"ms":1537803,"kind":"key","payload":{"kind":"up","key":"Backspace","character":null,"deferred":false,"handler":"ignored"}}
{"seq":358,"ms":1538021,"kind":"key","payload":{"kind":"down","key":"I","character":"i","deferred":true,"handler":"ignored"}}
{"seq":359,"ms":1538046,"kind":"deltas","payload":{"deltas":[{"type":"insertion","oldText":". hind","inserted":"i","at":6,"sel":[7,7],"composing":[2,7]}]}}
{"seq":360,"ms":1538089,"kind":"key","payload":{"kind":"up","key":"I","character":null,"deferred":false,"handler":"ignored"}}
{"seq":361,"ms":1539508,"kind":"key","payload":{"kind":"down","key":"Enter","character":"\r","deferred":true,"handler":"ignored"}}
{"seq":362,"ms":1539510,"kind":"deltas","payload":{"deltas":[{"type":"replacement","oldText":". hindi","replaced":[2,7],"text":"हिंदी ","sel":[8,8],"composing":null}]}}
{"seq":363,"ms":1539601,"kind":"key","payload":{"kind":"up","key":"Enter","character":null,"deferred":false,"handler":"ignored"}}
''';

  test('Hindi Transliteration: हिंदी (hindi) — mid-composing Backspace '
      'correction + Enter commit', () {
    buildService();
    replayImeJournal(service, parseImeJournalDump(hindiHindi));

    // The IME commits "हिंदी " (with trailing space).
    expect(blockText(), 'हिंदी ');
    expect(controller.composing, isNull);
    expect(service.currentTextEditingValue!.composing, TextRange.empty);
    expect(controller.selection!.isCollapsed, isTrue);

    final journal = service.journal.toJson();
    expect(
      journal.where((e) => e['kind'] == 'terminate'),
      isEmpty,
      reason: 'Enter committed via the IME delta, not a structural terminate',
    );
  });
}
