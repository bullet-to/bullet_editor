import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ime_replay.dart';
import 'ime_service_test.dart' show FakeImeConnection;

/// REAL Safari capture (nonDeltaDiff / snapshot frontend) of a multi-language
/// session: Korean 2-Set → Chinese Pinyin → Hindi Transliteration, all typed
/// sequentially in one block.
///
/// Safari's Korean 2-Set sends NO composing range — composing is always null,
/// matching macOS native delta-frontend behavior. Chrome's Korean, by contrast,
/// sends composing ranges. Both produce the same committed text.
///
/// Safari's Chinese/Hindi composing snapshots carry the composingSelectionAdopted
/// pattern: the first composing snapshot reports sel == composing (a non-collapsed
/// range over the marked text), immediately followed by a second snapshot with
/// sel collapsed to the end of composing. The pipeline's within-composing
/// selection adoption keeps the composition alive through this shape.
///
/// The capture starts mid-flight at seq 38 — "안녕" was already typed earlier in
/// the session and is not present in the capture. The document is initialized with
/// that text so the replay's first snapshot diffs correctly.
void main() {
  const capture = r'''
{"seq":38,"ms":38752,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕","inserted":" ","at":4,"sel":[5,5],"composing":null}}}
{"seq":39,"ms":38819,"kind":"key","payload":{"kind":"up","key":" ","character":null,"deferred":false,"handler":"ignored"}}
{"seq":40,"ms":41275,"kind":"snapshot","payload":{"text":". 안녕 ㅎ","sel":[6,6],"composing":null}}
{"seq":41,"ms":41275,"kind":"diff","payload":{"start":5,"deleted":0,"inserted":"ㅎ"}}
{"seq":42,"ms":41275,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 ","inserted":"ㅎ","at":5,"sel":[6,6],"composing":null}}}
{"seq":43,"ms":41308,"kind":"key","payload":{"kind":"down","key":"G","character":"ㅎ","deferred":false,"handler":"ignored"}}
{"seq":44,"ms":41357,"kind":"key","payload":{"kind":"up","key":"G","character":null,"deferred":false,"handler":"ignored"}}
{"seq":45,"ms":41533,"kind":"snapshot","payload":{"text":". 안녕 하","sel":[6,6],"composing":null}}
{"seq":46,"ms":41533,"kind":"diff","payload":{"start":5,"deleted":1,"inserted":"하"}}
{"seq":47,"ms":41533,"kind":"synthesized","payload":{"delta":{"type":"replacement","oldText":". 안녕 ㅎ","replaced":[5,6],"text":"하","sel":[6,6],"composing":null}}}
{"seq":48,"ms":41534,"kind":"key","payload":{"kind":"down","key":"K","character":"ㅏ","deferred":false,"handler":"ignored"}}
{"seq":49,"ms":41630,"kind":"key","payload":{"kind":"up","key":"K","character":null,"deferred":false,"handler":"ignored"}}
{"seq":50,"ms":41895,"kind":"snapshot","payload":{"text":". 안녕 한","sel":[6,6],"composing":null}}
{"seq":51,"ms":41895,"kind":"diff","payload":{"start":5,"deleted":1,"inserted":"한"}}
{"seq":52,"ms":41895,"kind":"synthesized","payload":{"delta":{"type":"replacement","oldText":". 안녕 하","replaced":[5,6],"text":"한","sel":[6,6],"composing":null}}}
{"seq":53,"ms":41898,"kind":"key","payload":{"kind":"down","key":"S","character":"ㄴ","deferred":false,"handler":"ignored"}}
{"seq":54,"ms":41998,"kind":"key","payload":{"kind":"up","key":"S","character":null,"deferred":false,"handler":"ignored"}}
{"seq":55,"ms":43135,"kind":"snapshot","payload":{"text":". 안녕 한ㄱ","sel":[7,7],"composing":null}}
{"seq":56,"ms":43135,"kind":"diff","payload":{"start":6,"deleted":0,"inserted":"ㄱ"}}
{"seq":57,"ms":43135,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한","inserted":"ㄱ","at":6,"sel":[7,7],"composing":null}}}
{"seq":58,"ms":43138,"kind":"key","payload":{"kind":"down","key":"R","character":"ㄱ","deferred":false,"handler":"ignored"}}
{"seq":59,"ms":43216,"kind":"key","payload":{"kind":"up","key":"R","character":null,"deferred":false,"handler":"ignored"}}
{"seq":60,"ms":43501,"kind":"snapshot","payload":{"text":". 안녕 한그","sel":[7,7],"composing":null}}
{"seq":61,"ms":43501,"kind":"diff","payload":{"start":6,"deleted":1,"inserted":"그"}}
{"seq":62,"ms":43501,"kind":"synthesized","payload":{"delta":{"type":"replacement","oldText":". 안녕 한ㄱ","replaced":[6,7],"text":"그","sel":[7,7],"composing":null}}}
{"seq":63,"ms":43502,"kind":"key","payload":{"kind":"down","key":"M","character":"ㅡ","deferred":false,"handler":"ignored"}}
{"seq":64,"ms":43607,"kind":"key","payload":{"kind":"up","key":"M","character":null,"deferred":false,"handler":"ignored"}}
{"seq":65,"ms":44317,"kind":"snapshot","payload":{"text":". 안녕 한글","sel":[7,7],"composing":null}}
{"seq":66,"ms":44317,"kind":"diff","payload":{"start":6,"deleted":1,"inserted":"글"}}
{"seq":67,"ms":44317,"kind":"synthesized","payload":{"delta":{"type":"replacement","oldText":". 안녕 한그","replaced":[6,7],"text":"글","sel":[7,7],"composing":null}}}
{"seq":68,"ms":44319,"kind":"key","payload":{"kind":"down","key":"F","character":"ㄹ","deferred":false,"handler":"ignored"}}
{"seq":69,"ms":44381,"kind":"key","payload":{"kind":"up","key":"F","character":null,"deferred":false,"handler":"ignored"}}
{"seq":70,"ms":45941,"kind":"key","payload":{"kind":"down","key":" ","character":" ","deferred":false,"handler":"ignored"}}
{"seq":71,"ms":45943,"kind":"snapshot","payload":{"text":". 안녕 한글 ","sel":[8,8],"composing":null}}
{"seq":72,"ms":45944,"kind":"diff","payload":{"start":7,"deleted":0,"inserted":" "}}
{"seq":73,"ms":45944,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글","inserted":" ","at":7,"sel":[8,8],"composing":null}}}
{"seq":74,"ms":46006,"kind":"key","payload":{"kind":"up","key":" ","character":null,"deferred":false,"handler":"ignored"}}
{"seq":75,"ms":52030,"kind":"snapshot","payload":{"text":". 안녕 한글 n","sel":[8,9],"composing":[8,9]}}
{"seq":76,"ms":52030,"kind":"diff","payload":{"start":8,"deleted":0,"inserted":"n"}}
{"seq":77,"ms":52030,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 ","inserted":"n","at":8,"sel":[8,9],"composing":[8,9]}}}
{"seq":78,"ms":52031,"kind":"composingSelectionAdopted","payload":{"sel":[8,9],"composing":[8,9]}}
{"seq":79,"ms":52078,"kind":"snapshot","payload":{"text":". 안녕 한글 n","sel":[9,9],"composing":[8,9]}}
{"seq":80,"ms":52078,"kind":"diff","payload":{"result":null}}
{"seq":81,"ms":52078,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 n","sel":[9,9],"composing":[8,9]}}}
{"seq":82,"ms":52104,"kind":"key","payload":{"kind":"down","key":"N","character":"n","deferred":true,"handler":"ignored"}}
{"seq":83,"ms":52123,"kind":"key","payload":{"kind":"up","key":"N","character":null,"deferred":false,"handler":"ignored"}}
{"seq":84,"ms":52140,"kind":"snapshot","payload":{"text":". 안녕 한글 ni","sel":[8,10],"composing":[8,10]}}
{"seq":85,"ms":52140,"kind":"diff","payload":{"start":9,"deleted":0,"inserted":"i"}}
{"seq":86,"ms":52140,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 n","inserted":"i","at":9,"sel":[8,10],"composing":[8,10]}}}
{"seq":87,"ms":52140,"kind":"composingSelectionAdopted","payload":{"sel":[8,10],"composing":[8,10]}}
{"seq":88,"ms":52141,"kind":"snapshot","payload":{"text":". 안녕 한글 ni","sel":[10,10],"composing":[8,10]}}
{"seq":89,"ms":52141,"kind":"diff","payload":{"result":null}}
{"seq":90,"ms":52141,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 ni","sel":[10,10],"composing":[8,10]}}}
{"seq":91,"ms":52169,"kind":"key","payload":{"kind":"down","key":"I","character":"i","deferred":true,"handler":"ignored"}}
{"seq":92,"ms":52195,"kind":"key","payload":{"kind":"up","key":"I","character":null,"deferred":false,"handler":"ignored"}}
{"seq":93,"ms":52328,"kind":"snapshot","payload":{"text":". 안녕 한글 ni h","sel":[8,12],"composing":[8,12]}}
{"seq":94,"ms":52328,"kind":"diff","payload":{"start":10,"deleted":0,"inserted":" h"}}
{"seq":95,"ms":52328,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 ni","inserted":" h","at":10,"sel":[8,12],"composing":[8,12]}}}
{"seq":96,"ms":52328,"kind":"composingSelectionAdopted","payload":{"sel":[8,12],"composing":[8,12]}}
{"seq":97,"ms":52329,"kind":"snapshot","payload":{"text":". 안녕 한글 ni h","sel":[12,12],"composing":[8,12]}}
{"seq":98,"ms":52329,"kind":"diff","payload":{"result":null}}
{"seq":99,"ms":52329,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 ni h","sel":[12,12],"composing":[8,12]}}}
{"seq":100,"ms":52355,"kind":"key","payload":{"kind":"down","key":"H","character":"h","deferred":true,"handler":"ignored"}}
{"seq":101,"ms":52382,"kind":"key","payload":{"kind":"up","key":"H","character":null,"deferred":false,"handler":"ignored"}}
{"seq":102,"ms":52422,"kind":"snapshot","payload":{"text":". 안녕 한글 ni ha","sel":[8,13],"composing":[8,13]}}
{"seq":103,"ms":52422,"kind":"diff","payload":{"start":12,"deleted":0,"inserted":"a"}}
{"seq":104,"ms":52422,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 ni h","inserted":"a","at":12,"sel":[8,13],"composing":[8,13]}}}
{"seq":105,"ms":52422,"kind":"composingSelectionAdopted","payload":{"sel":[8,13],"composing":[8,13]}}
{"seq":106,"ms":52423,"kind":"snapshot","payload":{"text":". 안녕 한글 ni ha","sel":[13,13],"composing":[8,13]}}
{"seq":107,"ms":52423,"kind":"diff","payload":{"result":null}}
{"seq":108,"ms":52423,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 ni ha","sel":[13,13],"composing":[8,13]}}}
{"seq":109,"ms":52426,"kind":"key","payload":{"kind":"down","key":"A","character":"a","deferred":true,"handler":"ignored"}}
{"seq":110,"ms":52502,"kind":"key","payload":{"kind":"up","key":"A","character":null,"deferred":false,"handler":"ignored"}}
{"seq":111,"ms":52589,"kind":"snapshot","payload":{"text":". 안녕 한글 ni hao","sel":[8,14],"composing":[8,14]}}
{"seq":112,"ms":52589,"kind":"diff","payload":{"start":13,"deleted":0,"inserted":"o"}}
{"seq":113,"ms":52589,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 ni ha","inserted":"o","at":13,"sel":[8,14],"composing":[8,14]}}}
{"seq":114,"ms":52589,"kind":"composingSelectionAdopted","payload":{"sel":[8,14],"composing":[8,14]}}
{"seq":115,"ms":52589,"kind":"snapshot","payload":{"text":". 안녕 한글 ni hao","sel":[14,14],"composing":[8,14]}}
{"seq":116,"ms":52589,"kind":"diff","payload":{"result":null}}
{"seq":117,"ms":52589,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 ni hao","sel":[14,14],"composing":[8,14]}}}
{"seq":118,"ms":52616,"kind":"key","payload":{"kind":"down","key":"O","character":"o","deferred":true,"handler":"ignored"}}
{"seq":119,"ms":52628,"kind":"key","payload":{"kind":"up","key":"O","character":null,"deferred":false,"handler":"ignored"}}
{"seq":120,"ms":53212,"kind":"snapshot","payload":{"text":". 안녕 한글 你好","sel":[10,10],"composing":null}}
{"seq":121,"ms":53212,"kind":"diff","payload":{"start":8,"deleted":6,"inserted":"你好"}}
{"seq":122,"ms":53212,"kind":"synthesized","payload":{"delta":{"type":"replacement","oldText":". 안녕 한글 ni hao","replaced":[8,14],"text":"你好","sel":[10,10],"composing":null}}}
{"seq":123,"ms":53212,"kind":"commitKeySuppressionArmed","payload":{}}
{"seq":124,"ms":53213,"kind":"key","payload":{"kind":"down","key":" ","character":" ","deferred":false,"handler":"ignored"}}
{"seq":125,"ms":53242,"kind":"key","payload":{"kind":"up","key":" ","character":null,"deferred":false,"handler":"ignored"}}
{"seq":126,"ms":55505,"kind":"snapshot","payload":{"text":". 안녕 한글 你好z","sel":[10,11],"composing":[10,11]}}
{"seq":127,"ms":55505,"kind":"diff","payload":{"start":10,"deleted":0,"inserted":"z"}}
{"seq":128,"ms":55505,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好","inserted":"z","at":10,"sel":[10,11],"composing":[10,11]}}}
{"seq":129,"ms":55505,"kind":"commitKeySuppressionDisarmed","payload":{"reason":"subsequentSnapshot"}}
{"seq":130,"ms":55506,"kind":"composingSelectionAdopted","payload":{"sel":[10,11],"composing":[10,11]}}
{"seq":131,"ms":55532,"kind":"snapshot","payload":{"text":". 안녕 한글 你好z","sel":[11,11],"composing":[10,11]}}
{"seq":132,"ms":55532,"kind":"diff","payload":{"result":null}}
{"seq":133,"ms":55532,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好z","sel":[11,11],"composing":[10,11]}}}
{"seq":134,"ms":55541,"kind":"key","payload":{"kind":"down","key":"Z","character":"z","deferred":true,"handler":"ignored"}}
{"seq":135,"ms":55573,"kind":"key","payload":{"kind":"up","key":"Z","character":null,"deferred":false,"handler":"ignored"}}
{"seq":136,"ms":55667,"kind":"snapshot","payload":{"text":". 안녕 한글 你好zh","sel":[10,12],"composing":[10,12]}}
{"seq":137,"ms":55667,"kind":"diff","payload":{"start":11,"deleted":0,"inserted":"h"}}
{"seq":138,"ms":55667,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好z","inserted":"h","at":11,"sel":[10,12],"composing":[10,12]}}}
{"seq":139,"ms":55667,"kind":"composingSelectionAdopted","payload":{"sel":[10,12],"composing":[10,12]}}
{"seq":140,"ms":55667,"kind":"snapshot","payload":{"text":". 안녕 한글 你好zh","sel":[12,12],"composing":[10,12]}}
{"seq":141,"ms":55667,"kind":"diff","payload":{"result":null}}
{"seq":142,"ms":55667,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好zh","sel":[12,12],"composing":[10,12]}}}
{"seq":143,"ms":55692,"kind":"key","payload":{"kind":"down","key":"H","character":"h","deferred":true,"handler":"ignored"}}
{"seq":144,"ms":55718,"kind":"key","payload":{"kind":"up","key":"H","character":null,"deferred":false,"handler":"ignored"}}
{"seq":145,"ms":55859,"kind":"snapshot","payload":{"text":". 안녕 한글 你好zho","sel":[10,13],"composing":[10,13]}}
{"seq":146,"ms":55859,"kind":"diff","payload":{"start":12,"deleted":0,"inserted":"o"}}
{"seq":147,"ms":55859,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好zh","inserted":"o","at":12,"sel":[10,13],"composing":[10,13]}}}
{"seq":148,"ms":55859,"kind":"composingSelectionAdopted","payload":{"sel":[10,13],"composing":[10,13]}}
{"seq":149,"ms":55859,"kind":"snapshot","payload":{"text":". 안녕 한글 你好zho","sel":[13,13],"composing":[10,13]}}
{"seq":150,"ms":55859,"kind":"diff","payload":{"result":null}}
{"seq":151,"ms":55859,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好zho","sel":[13,13],"composing":[10,13]}}}
{"seq":152,"ms":55883,"kind":"key","payload":{"kind":"down","key":"O","character":"o","deferred":true,"handler":"ignored"}}
{"seq":153,"ms":55917,"kind":"key","payload":{"kind":"up","key":"O","character":null,"deferred":false,"handler":"ignored"}}
{"seq":154,"ms":56054,"kind":"snapshot","payload":{"text":". 안녕 한글 你好zhon","sel":[10,14],"composing":[10,14]}}
{"seq":155,"ms":56054,"kind":"diff","payload":{"start":13,"deleted":0,"inserted":"n"}}
{"seq":156,"ms":56054,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好zho","inserted":"n","at":13,"sel":[10,14],"composing":[10,14]}}}
{"seq":157,"ms":56054,"kind":"composingSelectionAdopted","payload":{"sel":[10,14],"composing":[10,14]}}
{"seq":158,"ms":56055,"kind":"snapshot","payload":{"text":". 안녕 한글 你好zhon","sel":[14,14],"composing":[10,14]}}
{"seq":159,"ms":56055,"kind":"diff","payload":{"result":null}}
{"seq":160,"ms":56055,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好zhon","sel":[14,14],"composing":[10,14]}}}
{"seq":161,"ms":56079,"kind":"key","payload":{"kind":"down","key":"N","character":"n","deferred":true,"handler":"ignored"}}
{"seq":162,"ms":56118,"kind":"key","payload":{"kind":"up","key":"N","character":null,"deferred":false,"handler":"ignored"}}
{"seq":163,"ms":56271,"kind":"snapshot","payload":{"text":". 안녕 한글 你好zhong","sel":[10,15],"composing":[10,15]}}
{"seq":164,"ms":56271,"kind":"diff","payload":{"start":14,"deleted":0,"inserted":"g"}}
{"seq":165,"ms":56271,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好zhon","inserted":"g","at":14,"sel":[10,15],"composing":[10,15]}}}
{"seq":166,"ms":56272,"kind":"composingSelectionAdopted","payload":{"sel":[10,15],"composing":[10,15]}}
{"seq":167,"ms":56273,"kind":"snapshot","payload":{"text":". 안녕 한글 你好zhong","sel":[15,15],"composing":[10,15]}}
{"seq":168,"ms":56273,"kind":"diff","payload":{"result":null}}
{"seq":169,"ms":56273,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好zhong","sel":[15,15],"composing":[10,15]}}}
{"seq":170,"ms":56302,"kind":"key","payload":{"kind":"down","key":"G","character":"g","deferred":true,"handler":"ignored"}}
{"seq":171,"ms":56343,"kind":"key","payload":{"kind":"up","key":"G","character":null,"deferred":false,"handler":"ignored"}}
{"seq":172,"ms":57205,"kind":"snapshot","payload":{"text":". 안녕 한글 你好zhong g","sel":[10,17],"composing":[10,17]}}
{"seq":173,"ms":57205,"kind":"diff","payload":{"start":15,"deleted":0,"inserted":" g"}}
{"seq":174,"ms":57205,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好zhong","inserted":" g","at":15,"sel":[10,17],"composing":[10,17]}}}
{"seq":175,"ms":57206,"kind":"composingSelectionAdopted","payload":{"sel":[10,17],"composing":[10,17]}}
{"seq":176,"ms":57207,"kind":"snapshot","payload":{"text":". 안녕 한글 你好zhong g","sel":[17,17],"composing":[10,17]}}
{"seq":177,"ms":57207,"kind":"diff","payload":{"result":null}}
{"seq":178,"ms":57207,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好zhong g","sel":[17,17],"composing":[10,17]}}}
{"seq":179,"ms":57241,"kind":"key","payload":{"kind":"down","key":"G","character":"g","deferred":true,"handler":"ignored"}}
{"seq":180,"ms":57268,"kind":"key","payload":{"kind":"up","key":"G","character":null,"deferred":false,"handler":"ignored"}}
{"seq":181,"ms":57360,"kind":"snapshot","payload":{"text":". 안녕 한글 你好zhong gu","sel":[10,18],"composing":[10,18]}}
{"seq":182,"ms":57360,"kind":"diff","payload":{"start":17,"deleted":0,"inserted":"u"}}
{"seq":183,"ms":57360,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好zhong g","inserted":"u","at":17,"sel":[10,18],"composing":[10,18]}}}
{"seq":184,"ms":57360,"kind":"composingSelectionAdopted","payload":{"sel":[10,18],"composing":[10,18]}}
{"seq":185,"ms":57361,"kind":"snapshot","payload":{"text":". 안녕 한글 你好zhong gu","sel":[18,18],"composing":[10,18]}}
{"seq":186,"ms":57361,"kind":"diff","payload":{"result":null}}
{"seq":187,"ms":57361,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好zhong gu","sel":[18,18],"composing":[10,18]}}}
{"seq":188,"ms":57384,"kind":"key","payload":{"kind":"down","key":"U","character":"u","deferred":true,"handler":"ignored"}}
{"seq":189,"ms":57420,"kind":"key","payload":{"kind":"up","key":"U","character":null,"deferred":false,"handler":"ignored"}}
{"seq":190,"ms":57653,"kind":"snapshot","payload":{"text":". 안녕 한글 你好zhong guo","sel":[10,19],"composing":[10,19]}}
{"seq":191,"ms":57653,"kind":"diff","payload":{"start":18,"deleted":0,"inserted":"o"}}
{"seq":192,"ms":57653,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好zhong gu","inserted":"o","at":18,"sel":[10,19],"composing":[10,19]}}}
{"seq":193,"ms":57654,"kind":"composingSelectionAdopted","payload":{"sel":[10,19],"composing":[10,19]}}
{"seq":194,"ms":57654,"kind":"snapshot","payload":{"text":". 안녕 한글 你好zhong guo","sel":[19,19],"composing":[10,19]}}
{"seq":195,"ms":57654,"kind":"diff","payload":{"result":null}}
{"seq":196,"ms":57654,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好zhong guo","sel":[19,19],"composing":[10,19]}}}
{"seq":197,"ms":57687,"kind":"key","payload":{"kind":"down","key":"O","character":"o","deferred":true,"handler":"ignored"}}
{"seq":198,"ms":57728,"kind":"key","payload":{"kind":"up","key":"O","character":null,"deferred":false,"handler":"ignored"}}
{"seq":199,"ms":58594,"kind":"key","payload":{"kind":"down","key":" ","character":" ","deferred":true,"handler":"ignored"}}
{"seq":200,"ms":58594,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国","sel":[12,12],"composing":null}}
{"seq":201,"ms":58594,"kind":"diff","payload":{"start":10,"deleted":9,"inserted":"中国"}}
{"seq":202,"ms":58594,"kind":"synthesized","payload":{"delta":{"type":"replacement","oldText":". 안녕 한글 你好zhong guo","replaced":[10,19],"text":"中国","sel":[12,12],"composing":null}}}
{"seq":203,"ms":58595,"kind":"commitKeySuppressionArmed","payload":{}}
{"seq":204,"ms":58658,"kind":"key","payload":{"kind":"up","key":" ","character":null,"deferred":false,"handler":"ignored"}}
{"seq":205,"ms":60850,"kind":"key","payload":{"kind":"down","key":" ","character":" ","deferred":false,"handler":"ignored"}}
{"seq":206,"ms":60852,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 ","sel":[13,13],"composing":null}}
{"seq":207,"ms":60853,"kind":"diff","payload":{"start":12,"deleted":0,"inserted":" "}}
{"seq":208,"ms":60853,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国","inserted":" ","at":12,"sel":[13,13],"composing":null}}}
{"seq":209,"ms":60853,"kind":"commitKeySuppressionDisarmed","payload":{"reason":"subsequentSnapshot"}}
{"seq":210,"ms":60914,"kind":"key","payload":{"kind":"up","key":" ","character":null,"deferred":false,"handler":"ignored"}}
{"seq":211,"ms":79065,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 n","sel":[13,14],"composing":[13,14]}}
{"seq":212,"ms":79065,"kind":"diff","payload":{"start":13,"deleted":0,"inserted":"n"}}
{"seq":213,"ms":79065,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 ","inserted":"n","at":13,"sel":[13,14],"composing":[13,14]}}}
{"seq":214,"ms":79067,"kind":"composingSelectionAdopted","payload":{"sel":[13,14],"composing":[13,14]}}
{"seq":215,"ms":79069,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 n","sel":[14,14],"composing":[13,14]}}
{"seq":216,"ms":79069,"kind":"diff","payload":{"result":null}}
{"seq":217,"ms":79069,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好中国 n","sel":[14,14],"composing":[13,14]}}}
{"seq":218,"ms":79072,"kind":"key","payload":{"kind":"down","key":"N","character":"n","deferred":true,"handler":"ignored"}}
{"seq":219,"ms":79112,"kind":"key","payload":{"kind":"up","key":"N","character":null,"deferred":false,"handler":"ignored"}}
{"seq":220,"ms":79133,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 na","sel":[13,15],"composing":[13,15]}}
{"seq":221,"ms":79133,"kind":"diff","payload":{"start":14,"deleted":0,"inserted":"a"}}
{"seq":222,"ms":79133,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 n","inserted":"a","at":14,"sel":[13,15],"composing":[13,15]}}}
{"seq":223,"ms":79133,"kind":"composingSelectionAdopted","payload":{"sel":[13,15],"composing":[13,15]}}
{"seq":224,"ms":79134,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 na","sel":[15,15],"composing":[13,15]}}
{"seq":225,"ms":79134,"kind":"diff","payload":{"result":null}}
{"seq":226,"ms":79134,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好中国 na","sel":[15,15],"composing":[13,15]}}}
{"seq":227,"ms":79134,"kind":"key","payload":{"kind":"down","key":"A","character":"a","deferred":true,"handler":"ignored"}}
{"seq":228,"ms":79162,"kind":"key","payload":{"kind":"up","key":"A","character":null,"deferred":false,"handler":"ignored"}}
{"seq":229,"ms":79180,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 nam","sel":[13,16],"composing":[13,16]}}
{"seq":230,"ms":79180,"kind":"diff","payload":{"start":15,"deleted":0,"inserted":"m"}}
{"seq":231,"ms":79180,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 na","inserted":"m","at":15,"sel":[13,16],"composing":[13,16]}}}
{"seq":232,"ms":79180,"kind":"composingSelectionAdopted","payload":{"sel":[13,16],"composing":[13,16]}}
{"seq":233,"ms":79181,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 nam","sel":[16,16],"composing":[13,16]}}
{"seq":234,"ms":79181,"kind":"diff","payload":{"result":null}}
{"seq":235,"ms":79181,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好中国 nam","sel":[16,16],"composing":[13,16]}}}
{"seq":236,"ms":79181,"kind":"key","payload":{"kind":"down","key":"M","character":"m","deferred":true,"handler":"ignored"}}
{"seq":237,"ms":79233,"kind":"key","payload":{"kind":"up","key":"M","character":null,"deferred":false,"handler":"ignored"}}
{"seq":238,"ms":79251,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 nama","sel":[13,17],"composing":[13,17]}}
{"seq":239,"ms":79251,"kind":"diff","payload":{"start":16,"deleted":0,"inserted":"a"}}
{"seq":240,"ms":79251,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 nam","inserted":"a","at":16,"sel":[13,17],"composing":[13,17]}}}
{"seq":241,"ms":79251,"kind":"composingSelectionAdopted","payload":{"sel":[13,17],"composing":[13,17]}}
{"seq":242,"ms":79251,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 nama","sel":[17,17],"composing":[13,17]}}
{"seq":243,"ms":79251,"kind":"diff","payload":{"result":null}}
{"seq":244,"ms":79251,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好中国 nama","sel":[17,17],"composing":[13,17]}}}
{"seq":245,"ms":79252,"kind":"key","payload":{"kind":"down","key":"A","character":"a","deferred":true,"handler":"ignored"}}
{"seq":246,"ms":79342,"kind":"key","payload":{"kind":"up","key":"A","character":null,"deferred":false,"handler":"ignored"}}
{"seq":247,"ms":79502,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 namas","sel":[13,18],"composing":[13,18]}}
{"seq":248,"ms":79502,"kind":"diff","payload":{"start":17,"deleted":0,"inserted":"s"}}
{"seq":249,"ms":79502,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 nama","inserted":"s","at":17,"sel":[13,18],"composing":[13,18]}}}
{"seq":250,"ms":79503,"kind":"composingSelectionAdopted","payload":{"sel":[13,18],"composing":[13,18]}}
{"seq":251,"ms":79504,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 namas","sel":[18,18],"composing":[13,18]}}
{"seq":252,"ms":79504,"kind":"diff","payload":{"result":null}}
{"seq":253,"ms":79504,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好中国 namas","sel":[18,18],"composing":[13,18]}}}
{"seq":254,"ms":79528,"kind":"key","payload":{"kind":"down","key":"S","character":"s","deferred":true,"handler":"ignored"}}
{"seq":255,"ms":79560,"kind":"key","payload":{"kind":"up","key":"S","character":null,"deferred":false,"handler":"ignored"}}
{"seq":256,"ms":79668,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 namast","sel":[13,19],"composing":[13,19]}}
{"seq":257,"ms":79668,"kind":"diff","payload":{"start":18,"deleted":0,"inserted":"t"}}
{"seq":258,"ms":79669,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 namas","inserted":"t","at":18,"sel":[13,19],"composing":[13,19]}}}
{"seq":259,"ms":79669,"kind":"composingSelectionAdopted","payload":{"sel":[13,19],"composing":[13,19]}}
{"seq":260,"ms":79669,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 namast","sel":[19,19],"composing":[13,19]}}
{"seq":261,"ms":79669,"kind":"diff","payload":{"result":null}}
{"seq":262,"ms":79669,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好中国 namast","sel":[19,19],"composing":[13,19]}}}
{"seq":263,"ms":79692,"kind":"key","payload":{"kind":"down","key":"T","character":"t","deferred":true,"handler":"ignored"}}
{"seq":264,"ms":79768,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 namaste","sel":[13,20],"composing":[13,20]}}
{"seq":265,"ms":79768,"kind":"diff","payload":{"start":19,"deleted":0,"inserted":"e"}}
{"seq":266,"ms":79768,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 namast","inserted":"e","at":19,"sel":[13,20],"composing":[13,20]}}}
{"seq":267,"ms":79769,"kind":"composingSelectionAdopted","payload":{"sel":[13,20],"composing":[13,20]}}
{"seq":268,"ms":79769,"kind":"key","payload":{"kind":"down","key":"E","character":"e","deferred":true,"handler":"ignored"}}
{"seq":269,"ms":79769,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 namaste","sel":[20,20],"composing":[13,20]}}
{"seq":270,"ms":79769,"kind":"diff","payload":{"result":null}}
{"seq":271,"ms":79769,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好中国 namaste","sel":[20,20],"composing":[13,20]}}}
{"seq":272,"ms":79793,"kind":"key","payload":{"kind":"up","key":"T","character":null,"deferred":false,"handler":"ignored"}}
{"seq":273,"ms":79843,"kind":"key","payload":{"kind":"up","key":"E","character":null,"deferred":false,"handler":"ignored"}}
{"seq":274,"ms":79940,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते ","sel":[20,20],"composing":[13,20]}}
{"seq":275,"ms":79940,"kind":"diff","payload":{"start":13,"deleted":7,"inserted":"नमस्ते "}}
{"seq":276,"ms":79940,"kind":"synthesized","payload":{"delta":{"type":"replacement","oldText":". 안녕 한글 你好中国 namaste","replaced":[13,20],"text":"नमस्ते ","sel":[20,20],"composing":[13,20]}}}
{"seq":277,"ms":79941,"kind":"key","payload":{"kind":"down","key":" ","character":" ","deferred":true,"handler":"ignored"}}
{"seq":278,"ms":79942,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते ","sel":[20,20],"composing":null}}
{"seq":279,"ms":79942,"kind":"diff","payload":{"result":null}}
{"seq":280,"ms":79942,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好中国 नमस्ते ","sel":[20,20],"composing":null}}}
{"seq":281,"ms":79942,"kind":"commitKeySuppressionArmed","payload":{}}
{"seq":282,"ms":80030,"kind":"key","payload":{"kind":"up","key":" ","character":null,"deferred":false,"handler":"ignored"}}
{"seq":283,"ms":81852,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते h","sel":[20,21],"composing":[20,21]}}
{"seq":284,"ms":81852,"kind":"diff","payload":{"start":20,"deleted":0,"inserted":"h"}}
{"seq":285,"ms":81852,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 नमस्ते ","inserted":"h","at":20,"sel":[20,21],"composing":[20,21]}}}
{"seq":286,"ms":81852,"kind":"commitKeySuppressionDisarmed","payload":{"reason":"subsequentSnapshot"}}
{"seq":287,"ms":81853,"kind":"composingSelectionAdopted","payload":{"sel":[20,21],"composing":[20,21]}}
{"seq":288,"ms":81855,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते h","sel":[21,21],"composing":[20,21]}}
{"seq":289,"ms":81855,"kind":"diff","payload":{"result":null}}
{"seq":290,"ms":81855,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好中国 नमस्ते h","sel":[21,21],"composing":[20,21]}}}
{"seq":291,"ms":81856,"kind":"key","payload":{"kind":"down","key":"H","character":"h","deferred":true,"handler":"ignored"}}
{"seq":292,"ms":81935,"kind":"key","payload":{"kind":"up","key":"H","character":null,"deferred":false,"handler":"ignored"}}
{"seq":293,"ms":82066,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते hi","sel":[20,22],"composing":[20,22]}}
{"seq":294,"ms":82066,"kind":"diff","payload":{"start":21,"deleted":0,"inserted":"i"}}
{"seq":295,"ms":82066,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 नमस्ते h","inserted":"i","at":21,"sel":[20,22],"composing":[20,22]}}}
{"seq":296,"ms":82066,"kind":"composingSelectionAdopted","payload":{"sel":[20,22],"composing":[20,22]}}
{"seq":297,"ms":82067,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते hi","sel":[22,22],"composing":[20,22]}}
{"seq":298,"ms":82067,"kind":"diff","payload":{"result":null}}
{"seq":299,"ms":82067,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好中国 नमस्ते hi","sel":[22,22],"composing":[20,22]}}}
{"seq":300,"ms":82089,"kind":"key","payload":{"kind":"down","key":"I","character":"i","deferred":true,"handler":"ignored"}}
{"seq":301,"ms":82128,"kind":"key","payload":{"kind":"up","key":"I","character":null,"deferred":false,"handler":"ignored"}}
{"seq":302,"ms":82210,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते hin","sel":[20,23],"composing":[20,23]}}
{"seq":303,"ms":82210,"kind":"diff","payload":{"start":22,"deleted":0,"inserted":"n"}}
{"seq":304,"ms":82210,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 नमस्ते hi","inserted":"n","at":22,"sel":[20,23],"composing":[20,23]}}}
{"seq":305,"ms":82210,"kind":"composingSelectionAdopted","payload":{"sel":[20,23],"composing":[20,23]}}
{"seq":306,"ms":82211,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते hin","sel":[23,23],"composing":[20,23]}}
{"seq":307,"ms":82211,"kind":"diff","payload":{"result":null}}
{"seq":308,"ms":82211,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好中国 नमस्ते hin","sel":[23,23],"composing":[20,23]}}}
{"seq":309,"ms":82232,"kind":"key","payload":{"kind":"down","key":"N","character":"n","deferred":true,"handler":"ignored"}}
{"seq":310,"ms":82267,"kind":"key","payload":{"kind":"up","key":"N","character":null,"deferred":false,"handler":"ignored"}}
{"seq":311,"ms":82308,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते hind","sel":[20,24],"composing":[20,24]}}
{"seq":312,"ms":82308,"kind":"diff","payload":{"start":23,"deleted":0,"inserted":"d"}}
{"seq":313,"ms":82308,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 नमस्ते hin","inserted":"d","at":23,"sel":[20,24],"composing":[20,24]}}}
{"seq":314,"ms":82308,"kind":"composingSelectionAdopted","payload":{"sel":[20,24],"composing":[20,24]}}
{"seq":315,"ms":82308,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते hind","sel":[24,24],"composing":[20,24]}}
{"seq":316,"ms":82308,"kind":"diff","payload":{"result":null}}
{"seq":317,"ms":82308,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好中国 नमस्ते hind","sel":[24,24],"composing":[20,24]}}}
{"seq":318,"ms":82311,"kind":"key","payload":{"kind":"down","key":"D","character":"d","deferred":true,"handler":"ignored"}}
{"seq":319,"ms":82353,"kind":"key","payload":{"kind":"up","key":"D","character":null,"deferred":false,"handler":"ignored"}}
{"seq":320,"ms":82419,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते hindi","sel":[20,25],"composing":[20,25]}}
{"seq":321,"ms":82419,"kind":"diff","payload":{"start":24,"deleted":0,"inserted":"i"}}
{"seq":322,"ms":82419,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 नमस्ते hind","inserted":"i","at":24,"sel":[20,25],"composing":[20,25]}}}
{"seq":323,"ms":82420,"kind":"composingSelectionAdopted","payload":{"sel":[20,25],"composing":[20,25]}}
{"seq":324,"ms":82420,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते hindi","sel":[25,25],"composing":[20,25]}}
{"seq":325,"ms":82420,"kind":"diff","payload":{"result":null}}
{"seq":326,"ms":82420,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好中国 नमस्ते hindi","sel":[25,25],"composing":[20,25]}}}
{"seq":327,"ms":82441,"kind":"key","payload":{"kind":"down","key":"I","character":"i","deferred":true,"handler":"ignored"}}
{"seq":328,"ms":82468,"kind":"key","payload":{"kind":"up","key":"I","character":null,"deferred":false,"handler":"ignored"}}
{"seq":329,"ms":82831,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते हिंदी ","sel":[26,26],"composing":[20,25]}}
{"seq":330,"ms":82832,"kind":"diff","payload":{"start":20,"deleted":5,"inserted":"हिंदी "}}
{"seq":331,"ms":82832,"kind":"synthesized","payload":{"delta":{"type":"replacement","oldText":". 안녕 한글 你好中国 नमस्ते hindi","replaced":[20,25],"text":"हिंदी ","sel":[26,26],"composing":[20,25]}}}
{"seq":332,"ms":82834,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते हिंदी ","sel":[26,26],"composing":null}}
{"seq":333,"ms":82834,"kind":"diff","payload":{"result":null}}
{"seq":334,"ms":82834,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好中国 नमस्ते हिंदी ","sel":[26,26],"composing":null}}}
{"seq":335,"ms":82834,"kind":"commitKeySuppressionArmed","payload":{}}
{"seq":336,"ms":82834,"kind":"key","payload":{"kind":"down","key":" ","character":" ","deferred":false,"handler":"ignored"}}
{"seq":337,"ms":82882,"kind":"key","payload":{"kind":"up","key":" ","character":null,"deferred":false,"handler":"ignored"}}
''';

  test('Safari multi-language session: Korean → Chinese Pinyin → Hindi '
      'across IME switches in a single block', () {
    // The capture starts mid-flight (seq 38) with "안녕" already typed.
    final controller = EditorController(
      document: Document([
        TextBlock(
          id: 'a',
          blockType: ParagraphKeys.type,
          segments: [const StyledSegment('안녕')],
        ),
      ]),
      schema: EditorSchema.standard(),
      undoGrouping: (previous, current) => false,
    );
    controller
        .setSelection(DocSelection.collapsed(const DocPosition('a', 2)));
    final connections = <FakeImeConnection>[];
    final service = ImeService(
      controller: controller,
      frontend: ImeFrontend.nonDeltaDiff,
      connectionFactory: (client, configuration) {
        final connection = FakeImeConnection();
        connections.add(connection);
        return connection;
      },
    );
    service.attach();

    // No attach event in the capture — clear the initial push so
    // assertions on pushes only reflect what happened during replay.
    connections.last.pushed.clear();

    String blockText() => controller.document.allBlocks.last.plainText;

    replayImeJournal(service, parseImeJournalDump(capture));

    expect(blockText(), '안녕 한글 你好中国 नमस्ते हिंदी ');
    expect(controller.composing, isNull);
    expect(service.currentTextEditingValue!.composing, TextRange.empty);
    expect(controller.selection!.isCollapsed, isTrue);

    final journal = service.journal.toJson();
    final pushes = [
      for (final e in journal)
        if (e['kind'] == 'push')
          (e['payload']! as Map).cast<String, Object?>(),
    ];
    expect(
      [for (final p in pushes) p['viaTerminate']],
      everyElement(isFalse),
      reason: 'no push should be viaTerminate — all commits were clean',
    );
  });
}
