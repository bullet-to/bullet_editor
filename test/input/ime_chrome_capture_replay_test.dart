import 'package:bullet_editor/bullet_editor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ime_replay.dart';
import 'ime_service_test.dart' show FakeImeConnection;

/// REAL Chrome capture (nonDeltaDiff / snapshot frontend) of a multi-language
/// session: Korean 2-Set → Chinese Pinyin → Hindi Transliteration, all typed
/// sequentially in one block.
///
/// Chrome uses the diff frontend — every composing keystroke arrives as a full
/// `TextEditingValue` snapshot that the pipeline diffs against the shadow
/// buffer and synthesizes into an equivalent delta.
///
/// Notable Chrome behaviors visible in this capture:
/// - Korean composing carries a `composing` range (unlike macOS native delta
///   frontend, which sends null composing for Korean)
/// - Space commits Korean/Chinese/Hindi: the commit snapshot arrives with
///   composing still set, followed immediately by a second snapshot with
///   composing:null (the nonText update that clears it)
/// - The `commitKeySuppressionArmed` / `Disarmed` dance gates the post-commit
///   key from reaching the model as a structural edit
void main() {
  const capture = r'''
{"seq":0,"ms":80,"kind":"attach","payload":{"frontend":"nonDeltaDiff"}}
{"seq":1,"ms":87,"kind":"push","payload":{"text":". ","sel":[2,2],"composing":null,"viaTerminate":false}}
{"seq":2,"ms":5809,"kind":"detach","payload":{}}
{"seq":3,"ms":7330,"kind":"attach","payload":{"frontend":"nonDeltaDiff"}}
{"seq":4,"ms":7333,"kind":"push","payload":{"text":". ","sel":[2,2],"composing":null,"viaTerminate":false}}
{"seq":5,"ms":9237,"kind":"connectionClosed","payload":{}}
{"seq":6,"ms":9238,"kind":"terminate","payload":{"reason":"connectionClosed","composed":null}}
{"seq":7,"ms":17452,"kind":"attach","payload":{"frontend":"nonDeltaDiff"}}
{"seq":8,"ms":17455,"kind":"push","payload":{"text":". ","sel":[2,2],"composing":null,"viaTerminate":false}}
{"seq":9,"ms":20943,"kind":"key","payload":{"kind":"down","key":"D","character":"ㅇ","deferred":false,"handler":"ignored"}}
{"seq":10,"ms":20962,"kind":"snapshot","payload":{"text":". ㅇ","sel":[3,3],"composing":[2,3]}}
{"seq":11,"ms":20962,"kind":"diff","payload":{"start":2,"deleted":0,"inserted":"ㅇ"}}
{"seq":12,"ms":20963,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". ","inserted":"ㅇ","at":2,"sel":[3,3],"composing":[2,3]}}}
{"seq":13,"ms":21022,"kind":"key","payload":{"kind":"up","key":"D","character":null,"deferred":false,"handler":"ignored"}}
{"seq":14,"ms":21112,"kind":"key","payload":{"kind":"down","key":"K","character":"ㅏ","deferred":true,"handler":"ignored"}}
{"seq":15,"ms":21113,"kind":"snapshot","payload":{"text":". 아","sel":[3,3],"composing":[2,3]}}
{"seq":16,"ms":21113,"kind":"diff","payload":{"start":2,"deleted":1,"inserted":"아"}}
{"seq":17,"ms":21114,"kind":"synthesized","payload":{"delta":{"type":"replacement","oldText":". ㅇ","replaced":[2,3],"text":"아","sel":[3,3],"composing":[2,3]}}}
{"seq":18,"ms":21189,"kind":"key","payload":{"kind":"up","key":"K","character":null,"deferred":false,"handler":"ignored"}}
{"seq":19,"ms":21383,"kind":"key","payload":{"kind":"down","key":"S","character":"ㄴ","deferred":true,"handler":"ignored"}}
{"seq":20,"ms":21384,"kind":"snapshot","payload":{"text":". 안","sel":[3,3],"composing":[2,3]}}
{"seq":21,"ms":21384,"kind":"diff","payload":{"start":2,"deleted":1,"inserted":"안"}}
{"seq":22,"ms":21384,"kind":"synthesized","payload":{"delta":{"type":"replacement","oldText":". 아","replaced":[2,3],"text":"안","sel":[3,3],"composing":[2,3]}}}
{"seq":23,"ms":21458,"kind":"key","payload":{"kind":"up","key":"S","character":null,"deferred":false,"handler":"ignored"}}
{"seq":24,"ms":21937,"kind":"key","payload":{"kind":"down","key":"S","character":"ㄴ","deferred":true,"handler":"ignored"}}
{"seq":25,"ms":21938,"kind":"snapshot","payload":{"text":". 안ㄴ","sel":[4,4],"composing":[3,4]}}
{"seq":26,"ms":21938,"kind":"diff","payload":{"start":3,"deleted":0,"inserted":"ㄴ"}}
{"seq":27,"ms":21938,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안","inserted":"ㄴ","at":3,"sel":[4,4],"composing":[3,4]}}}
{"seq":28,"ms":22021,"kind":"key","payload":{"kind":"up","key":"S","character":null,"deferred":false,"handler":"ignored"}}
{"seq":29,"ms":22232,"kind":"key","payload":{"kind":"down","key":"U","character":"ㅕ","deferred":true,"handler":"ignored"}}
{"seq":30,"ms":22234,"kind":"snapshot","payload":{"text":". 안녀","sel":[4,4],"composing":[3,4]}}
{"seq":31,"ms":22234,"kind":"diff","payload":{"start":3,"deleted":1,"inserted":"녀"}}
{"seq":32,"ms":22234,"kind":"synthesized","payload":{"delta":{"type":"replacement","oldText":". 안ㄴ","replaced":[3,4],"text":"녀","sel":[4,4],"composing":[3,4]}}}
{"seq":33,"ms":22309,"kind":"key","payload":{"kind":"up","key":"U","character":null,"deferred":false,"handler":"ignored"}}
{"seq":34,"ms":22589,"kind":"key","payload":{"kind":"down","key":"D","character":"ㅇ","deferred":true,"handler":"ignored"}}
{"seq":35,"ms":22590,"kind":"snapshot","payload":{"text":". 안녕","sel":[4,4],"composing":[3,4]}}
{"seq":36,"ms":22590,"kind":"diff","payload":{"start":3,"deleted":1,"inserted":"녕"}}
{"seq":37,"ms":22590,"kind":"synthesized","payload":{"delta":{"type":"replacement","oldText":". 안녀","replaced":[3,4],"text":"녕","sel":[4,4],"composing":[3,4]}}}
{"seq":38,"ms":22716,"kind":"key","payload":{"kind":"up","key":"D","character":null,"deferred":false,"handler":"ignored"}}
{"seq":39,"ms":27835,"kind":"key","payload":{"kind":"down","key":" ","character":" ","deferred":true,"handler":"ignored"}}
{"seq":40,"ms":27836,"kind":"snapshot","payload":{"text":". 안녕 ","sel":[5,5],"composing":[3,5]}}
{"seq":41,"ms":27836,"kind":"diff","payload":{"start":4,"deleted":0,"inserted":" "}}
{"seq":42,"ms":27836,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕","inserted":" ","at":4,"sel":[5,5],"composing":[3,5]}}}
{"seq":43,"ms":27874,"kind":"snapshot","payload":{"text":". 안녕 ","sel":[5,5],"composing":null}}
{"seq":44,"ms":27874,"kind":"diff","payload":{"result":null}}
{"seq":45,"ms":27874,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 ","sel":[5,5],"composing":null}}}
{"seq":46,"ms":27874,"kind":"commitKeySuppressionArmed","payload":{}}
{"seq":47,"ms":27904,"kind":"key","payload":{"kind":"up","key":" ","character":null,"deferred":false,"handler":"ignored"}}
{"seq":48,"ms":31432,"kind":"key","payload":{"kind":"down","key":"G","character":"ㅎ","deferred":false,"handler":"ignored"}}
{"seq":49,"ms":31434,"kind":"snapshot","payload":{"text":". 안녕 ㅎ","sel":[6,6],"composing":[5,6]}}
{"seq":50,"ms":31434,"kind":"diff","payload":{"start":5,"deleted":0,"inserted":"ㅎ"}}
{"seq":51,"ms":31434,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 ","inserted":"ㅎ","at":5,"sel":[6,6],"composing":[5,6]}}}
{"seq":52,"ms":31434,"kind":"commitKeySuppressionDisarmed","payload":{"reason":"subsequentSnapshot"}}
{"seq":53,"ms":31509,"kind":"key","payload":{"kind":"up","key":"G","character":null,"deferred":false,"handler":"ignored"}}
{"seq":54,"ms":31769,"kind":"key","payload":{"kind":"down","key":"K","character":"ㅏ","deferred":true,"handler":"ignored"}}
{"seq":55,"ms":31772,"kind":"snapshot","payload":{"text":". 안녕 하","sel":[6,6],"composing":[5,6]}}
{"seq":56,"ms":31772,"kind":"diff","payload":{"start":5,"deleted":1,"inserted":"하"}}
{"seq":57,"ms":31772,"kind":"synthesized","payload":{"delta":{"type":"replacement","oldText":". 안녕 ㅎ","replaced":[5,6],"text":"하","sel":[6,6],"composing":[5,6]}}}
{"seq":58,"ms":31839,"kind":"key","payload":{"kind":"up","key":"K","character":null,"deferred":false,"handler":"ignored"}}
{"seq":59,"ms":31996,"kind":"key","payload":{"kind":"down","key":"S","character":"ㄴ","deferred":true,"handler":"ignored"}}
{"seq":60,"ms":31997,"kind":"snapshot","payload":{"text":". 안녕 한","sel":[6,6],"composing":[5,6]}}
{"seq":61,"ms":31997,"kind":"diff","payload":{"start":5,"deleted":1,"inserted":"한"}}
{"seq":62,"ms":31997,"kind":"synthesized","payload":{"delta":{"type":"replacement","oldText":". 안녕 하","replaced":[5,6],"text":"한","sel":[6,6],"composing":[5,6]}}}
{"seq":63,"ms":32121,"kind":"key","payload":{"kind":"up","key":"S","character":null,"deferred":false,"handler":"ignored"}}
{"seq":64,"ms":32327,"kind":"key","payload":{"kind":"down","key":"R","character":"ㄱ","deferred":true,"handler":"ignored"}}
{"seq":65,"ms":32329,"kind":"snapshot","payload":{"text":". 안녕 한ㄱ","sel":[7,7],"composing":[6,7]}}
{"seq":66,"ms":32329,"kind":"diff","payload":{"start":6,"deleted":0,"inserted":"ㄱ"}}
{"seq":67,"ms":32329,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한","inserted":"ㄱ","at":6,"sel":[7,7],"composing":[6,7]}}}
{"seq":68,"ms":32431,"kind":"key","payload":{"kind":"up","key":"R","character":null,"deferred":false,"handler":"ignored"}}
{"seq":69,"ms":32624,"kind":"key","payload":{"kind":"down","key":"M","character":"ㅡ","deferred":true,"handler":"ignored"}}
{"seq":70,"ms":32626,"kind":"snapshot","payload":{"text":". 안녕 한그","sel":[7,7],"composing":[6,7]}}
{"seq":71,"ms":32626,"kind":"diff","payload":{"start":6,"deleted":1,"inserted":"그"}}
{"seq":72,"ms":32626,"kind":"synthesized","payload":{"delta":{"type":"replacement","oldText":". 안녕 한ㄱ","replaced":[6,7],"text":"그","sel":[7,7],"composing":[6,7]}}}
{"seq":73,"ms":32731,"kind":"key","payload":{"kind":"up","key":"M","character":null,"deferred":false,"handler":"ignored"}}
{"seq":74,"ms":33077,"kind":"key","payload":{"kind":"down","key":"F","character":"ㄹ","deferred":true,"handler":"ignored"}}
{"seq":75,"ms":33078,"kind":"snapshot","payload":{"text":". 안녕 한글","sel":[7,7],"composing":[6,7]}}
{"seq":76,"ms":33078,"kind":"diff","payload":{"start":6,"deleted":1,"inserted":"글"}}
{"seq":77,"ms":33078,"kind":"synthesized","payload":{"delta":{"type":"replacement","oldText":". 안녕 한그","replaced":[6,7],"text":"글","sel":[7,7],"composing":[6,7]}}}
{"seq":78,"ms":33153,"kind":"key","payload":{"kind":"up","key":"F","character":null,"deferred":false,"handler":"ignored"}}
{"seq":79,"ms":34263,"kind":"key","payload":{"kind":"down","key":" ","character":" ","deferred":true,"handler":"ignored"}}
{"seq":80,"ms":34265,"kind":"snapshot","payload":{"text":". 안녕 한글 ","sel":[8,8],"composing":[6,8]}}
{"seq":81,"ms":34265,"kind":"diff","payload":{"start":7,"deleted":0,"inserted":" "}}
{"seq":82,"ms":34265,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글","inserted":" ","at":7,"sel":[8,8],"composing":[6,8]}}}
{"seq":83,"ms":34300,"kind":"snapshot","payload":{"text":". 안녕 한글 ","sel":[8,8],"composing":null}}
{"seq":84,"ms":34300,"kind":"diff","payload":{"result":null}}
{"seq":85,"ms":34300,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 ","sel":[8,8],"composing":null}}}
{"seq":86,"ms":34300,"kind":"commitKeySuppressionArmed","payload":{}}
{"seq":87,"ms":34337,"kind":"key","payload":{"kind":"up","key":" ","character":null,"deferred":false,"handler":"ignored"}}
{"seq":88,"ms":44128,"kind":"key","payload":{"kind":"down","key":"N","character":"n","deferred":false,"handler":"ignored"}}
{"seq":89,"ms":44131,"kind":"snapshot","payload":{"text":". 안녕 한글 n","sel":[9,9],"composing":[8,9]}}
{"seq":90,"ms":44131,"kind":"diff","payload":{"start":8,"deleted":0,"inserted":"n"}}
{"seq":91,"ms":44131,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 ","inserted":"n","at":8,"sel":[9,9],"composing":[8,9]}}}
{"seq":92,"ms":44131,"kind":"commitKeySuppressionDisarmed","payload":{"reason":"subsequentSnapshot"}}
{"seq":93,"ms":44179,"kind":"key","payload":{"kind":"up","key":"N","character":null,"deferred":false,"handler":"ignored"}}
{"seq":94,"ms":44237,"kind":"key","payload":{"kind":"down","key":"I","character":"i","deferred":true,"handler":"ignored"}}
{"seq":95,"ms":44237,"kind":"snapshot","payload":{"text":". 안녕 한글 ni","sel":[10,10],"composing":[8,10]}}
{"seq":96,"ms":44237,"kind":"diff","payload":{"start":9,"deleted":0,"inserted":"i"}}
{"seq":97,"ms":44237,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 n","inserted":"i","at":9,"sel":[10,10],"composing":[8,10]}}}
{"seq":98,"ms":44319,"kind":"key","payload":{"kind":"up","key":"I","character":null,"deferred":false,"handler":"ignored"}}
{"seq":99,"ms":44460,"kind":"key","payload":{"kind":"down","key":"H","character":"h","deferred":true,"handler":"ignored"}}
{"seq":100,"ms":44461,"kind":"snapshot","payload":{"text":". 안녕 한글 ni h","sel":[12,12],"composing":[8,12]}}
{"seq":101,"ms":44461,"kind":"diff","payload":{"start":10,"deleted":0,"inserted":" h"}}
{"seq":102,"ms":44461,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 ni","inserted":" h","at":10,"sel":[12,12],"composing":[8,12]}}}
{"seq":103,"ms":44512,"kind":"key","payload":{"kind":"up","key":"H","character":null,"deferred":false,"handler":"ignored"}}
{"seq":104,"ms":44688,"kind":"key","payload":{"kind":"down","key":"A","character":"a","deferred":true,"handler":"ignored"}}
{"seq":105,"ms":44689,"kind":"snapshot","payload":{"text":". 안녕 한글 ni ha","sel":[13,13],"composing":[8,13]}}
{"seq":106,"ms":44689,"kind":"diff","payload":{"start":12,"deleted":0,"inserted":"a"}}
{"seq":107,"ms":44689,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 ni h","inserted":"a","at":12,"sel":[13,13],"composing":[8,13]}}}
{"seq":108,"ms":44761,"kind":"key","payload":{"kind":"up","key":"A","character":null,"deferred":false,"handler":"ignored"}}
{"seq":109,"ms":44823,"kind":"key","payload":{"kind":"down","key":"O","character":"o","deferred":true,"handler":"ignored"}}
{"seq":110,"ms":44823,"kind":"snapshot","payload":{"text":". 안녕 한글 ni hao","sel":[14,14],"composing":[8,14]}}
{"seq":111,"ms":44823,"kind":"diff","payload":{"start":13,"deleted":0,"inserted":"o"}}
{"seq":112,"ms":44824,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 ni ha","inserted":"o","at":13,"sel":[14,14],"composing":[8,14]}}}
{"seq":113,"ms":44883,"kind":"key","payload":{"kind":"up","key":"O","character":null,"deferred":false,"handler":"ignored"}}
{"seq":114,"ms":45881,"kind":"key","payload":{"kind":"down","key":" ","character":" ","deferred":true,"handler":"ignored"}}
{"seq":115,"ms":45889,"kind":"snapshot","payload":{"text":". 안녕 한글 你好","sel":[10,10],"composing":[8,10]}}
{"seq":116,"ms":45889,"kind":"diff","payload":{"start":8,"deleted":6,"inserted":"你好"}}
{"seq":117,"ms":45889,"kind":"synthesized","payload":{"delta":{"type":"replacement","oldText":". 안녕 한글 ni hao","replaced":[8,14],"text":"你好","sel":[10,10],"composing":[8,10]}}}
{"seq":118,"ms":45926,"kind":"snapshot","payload":{"text":". 안녕 한글 你好","sel":[10,10],"composing":null}}
{"seq":119,"ms":45926,"kind":"diff","payload":{"result":null}}
{"seq":120,"ms":45926,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好","sel":[10,10],"composing":null}}}
{"seq":121,"ms":45926,"kind":"commitKeySuppressionArmed","payload":{}}
{"seq":122,"ms":45961,"kind":"key","payload":{"kind":"up","key":" ","character":null,"deferred":false,"handler":"ignored"}}
{"seq":123,"ms":48957,"kind":"key","payload":{"kind":"down","key":"Z","character":"z","deferred":false,"handler":"ignored"}}
{"seq":124,"ms":48959,"kind":"snapshot","payload":{"text":". 안녕 한글 你好z","sel":[11,11],"composing":[10,11]}}
{"seq":125,"ms":48959,"kind":"diff","payload":{"start":10,"deleted":0,"inserted":"z"}}
{"seq":126,"ms":48959,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好","inserted":"z","at":10,"sel":[11,11],"composing":[10,11]}}}
{"seq":127,"ms":48959,"kind":"commitKeySuppressionDisarmed","payload":{"reason":"subsequentSnapshot"}}
{"seq":128,"ms":49023,"kind":"key","payload":{"kind":"up","key":"Z","character":null,"deferred":false,"handler":"ignored"}}
{"seq":129,"ms":49212,"kind":"key","payload":{"kind":"down","key":"H","character":"h","deferred":true,"handler":"ignored"}}
{"seq":130,"ms":49214,"kind":"snapshot","payload":{"text":". 안녕 한글 你好zh","sel":[12,12],"composing":[10,12]}}
{"seq":131,"ms":49214,"kind":"diff","payload":{"start":11,"deleted":0,"inserted":"h"}}
{"seq":132,"ms":49214,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好z","inserted":"h","at":11,"sel":[12,12],"composing":[10,12]}}}
{"seq":133,"ms":49262,"kind":"key","payload":{"kind":"up","key":"H","character":null,"deferred":false,"handler":"ignored"}}
{"seq":134,"ms":49512,"kind":"key","payload":{"kind":"down","key":"O","character":"o","deferred":true,"handler":"ignored"}}
{"seq":135,"ms":49514,"kind":"snapshot","payload":{"text":". 안녕 한글 你好zho","sel":[13,13],"composing":[10,13]}}
{"seq":136,"ms":49514,"kind":"diff","payload":{"start":12,"deleted":0,"inserted":"o"}}
{"seq":137,"ms":49514,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好zh","inserted":"o","at":12,"sel":[13,13],"composing":[10,13]}}}
{"seq":138,"ms":49580,"kind":"key","payload":{"kind":"up","key":"O","character":null,"deferred":false,"handler":"ignored"}}
{"seq":139,"ms":49838,"kind":"key","payload":{"kind":"down","key":"N","character":"n","deferred":true,"handler":"ignored"}}
{"seq":140,"ms":49840,"kind":"snapshot","payload":{"text":". 안녕 한글 你好zhon","sel":[14,14],"composing":[10,14]}}
{"seq":141,"ms":49840,"kind":"diff","payload":{"start":13,"deleted":0,"inserted":"n"}}
{"seq":142,"ms":49840,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好zho","inserted":"n","at":13,"sel":[14,14],"composing":[10,14]}}}
{"seq":143,"ms":49889,"kind":"key","payload":{"kind":"up","key":"N","character":null,"deferred":false,"handler":"ignored"}}
{"seq":144,"ms":50574,"kind":"key","payload":{"kind":"down","key":"G","character":"g","deferred":true,"handler":"ignored"}}
{"seq":145,"ms":50576,"kind":"snapshot","payload":{"text":". 안녕 한글 你好zhong","sel":[15,15],"composing":[10,15]}}
{"seq":146,"ms":50576,"kind":"diff","payload":{"start":14,"deleted":0,"inserted":"g"}}
{"seq":147,"ms":50576,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好zhon","inserted":"g","at":14,"sel":[15,15],"composing":[10,15]}}}
{"seq":148,"ms":50641,"kind":"key","payload":{"kind":"up","key":"G","character":null,"deferred":false,"handler":"ignored"}}
{"seq":149,"ms":50750,"kind":"key","payload":{"kind":"down","key":"G","character":"g","deferred":true,"handler":"ignored"}}
{"seq":150,"ms":50750,"kind":"snapshot","payload":{"text":". 안녕 한글 你好zhong g","sel":[17,17],"composing":[10,17]}}
{"seq":151,"ms":50750,"kind":"diff","payload":{"start":15,"deleted":0,"inserted":" g"}}
{"seq":152,"ms":50750,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好zhong","inserted":" g","at":15,"sel":[17,17],"composing":[10,17]}}}
{"seq":153,"ms":50817,"kind":"key","payload":{"kind":"up","key":"G","character":null,"deferred":false,"handler":"ignored"}}
{"seq":154,"ms":50892,"kind":"key","payload":{"kind":"down","key":"U","character":"u","deferred":true,"handler":"ignored"}}
{"seq":155,"ms":50893,"kind":"snapshot","payload":{"text":". 안녕 한글 你好zhong gu","sel":[18,18],"composing":[10,18]}}
{"seq":156,"ms":50893,"kind":"diff","payload":{"start":17,"deleted":0,"inserted":"u"}}
{"seq":157,"ms":50893,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好zhong g","inserted":"u","at":17,"sel":[18,18],"composing":[10,18]}}}
{"seq":158,"ms":50948,"kind":"key","payload":{"kind":"up","key":"U","character":null,"deferred":false,"handler":"ignored"}}
{"seq":159,"ms":51117,"kind":"key","payload":{"kind":"down","key":"O","character":"o","deferred":true,"handler":"ignored"}}
{"seq":160,"ms":51118,"kind":"snapshot","payload":{"text":". 안녕 한글 你好zhong guo","sel":[19,19],"composing":[10,19]}}
{"seq":161,"ms":51118,"kind":"diff","payload":{"start":18,"deleted":0,"inserted":"o"}}
{"seq":162,"ms":51118,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好zhong gu","inserted":"o","at":18,"sel":[19,19],"composing":[10,19]}}}
{"seq":163,"ms":51183,"kind":"key","payload":{"kind":"up","key":"O","character":null,"deferred":false,"handler":"ignored"}}
{"seq":164,"ms":52071,"kind":"key","payload":{"kind":"down","key":" ","character":" ","deferred":true,"handler":"ignored"}}
{"seq":165,"ms":52071,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国","sel":[12,12],"composing":[10,12]}}
{"seq":166,"ms":52071,"kind":"diff","payload":{"start":10,"deleted":9,"inserted":"中国"}}
{"seq":167,"ms":52072,"kind":"synthesized","payload":{"delta":{"type":"replacement","oldText":". 안녕 한글 你好zhong guo","replaced":[10,19],"text":"中国","sel":[12,12],"composing":[10,12]}}}
{"seq":168,"ms":52107,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国","sel":[12,12],"composing":null}}
{"seq":169,"ms":52107,"kind":"diff","payload":{"result":null}}
{"seq":170,"ms":52107,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好中国","sel":[12,12],"composing":null}}}
{"seq":171,"ms":52107,"kind":"commitKeySuppressionArmed","payload":{}}
{"seq":172,"ms":52146,"kind":"key","payload":{"kind":"up","key":" ","character":null,"deferred":false,"handler":"ignored"}}
{"seq":173,"ms":59951,"kind":"key","payload":{"kind":"down","key":" ","character":" ","deferred":false,"handler":"ignored"}}
{"seq":174,"ms":59956,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 ","sel":[13,13],"composing":null}}
{"seq":175,"ms":59956,"kind":"diff","payload":{"start":12,"deleted":0,"inserted":" "}}
{"seq":176,"ms":59956,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国","inserted":" ","at":12,"sel":[13,13],"composing":null}}}
{"seq":177,"ms":59956,"kind":"commitKeySuppressionDisarmed","payload":{"reason":"subsequentSnapshot"}}
{"seq":178,"ms":60017,"kind":"key","payload":{"kind":"up","key":" ","character":null,"deferred":false,"handler":"ignored"}}
{"seq":179,"ms":68110,"kind":"key","payload":{"kind":"down","key":"N","character":"n","deferred":false,"handler":"ignored"}}
{"seq":180,"ms":68113,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 n","sel":[14,14],"composing":[13,14]}}
{"seq":181,"ms":68114,"kind":"diff","payload":{"start":13,"deleted":0,"inserted":"n"}}
{"seq":182,"ms":68114,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 ","inserted":"n","at":13,"sel":[14,14],"composing":[13,14]}}}
{"seq":183,"ms":68115,"kind":"key","payload":{"kind":"up","key":"N","character":null,"deferred":false,"handler":"ignored"}}
{"seq":184,"ms":68275,"kind":"key","payload":{"kind":"down","key":"A","character":"a","deferred":true,"handler":"ignored"}}
{"seq":185,"ms":68277,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 na","sel":[15,15],"composing":[13,15]}}
{"seq":186,"ms":68277,"kind":"diff","payload":{"start":14,"deleted":0,"inserted":"a"}}
{"seq":187,"ms":68277,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 n","inserted":"a","at":14,"sel":[15,15],"composing":[13,15]}}}
{"seq":188,"ms":68362,"kind":"key","payload":{"kind":"up","key":"A","character":null,"deferred":false,"handler":"ignored"}}
{"seq":189,"ms":68630,"kind":"key","payload":{"kind":"down","key":"M","character":"m","deferred":true,"handler":"ignored"}}
{"seq":190,"ms":68632,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 nam","sel":[16,16],"composing":[13,16]}}
{"seq":191,"ms":68632,"kind":"diff","payload":{"start":15,"deleted":0,"inserted":"m"}}
{"seq":192,"ms":68632,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 na","inserted":"m","at":15,"sel":[16,16],"composing":[13,16]}}}
{"seq":193,"ms":68700,"kind":"key","payload":{"kind":"up","key":"M","character":null,"deferred":false,"handler":"ignored"}}
{"seq":194,"ms":68835,"kind":"key","payload":{"kind":"down","key":"A","character":"a","deferred":true,"handler":"ignored"}}
{"seq":195,"ms":68836,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 nama","sel":[17,17],"composing":[13,17]}}
{"seq":196,"ms":68837,"kind":"diff","payload":{"start":16,"deleted":0,"inserted":"a"}}
{"seq":197,"ms":68837,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 nam","inserted":"a","at":16,"sel":[17,17],"composing":[13,17]}}}
{"seq":198,"ms":68906,"kind":"key","payload":{"kind":"up","key":"A","character":null,"deferred":false,"handler":"ignored"}}
{"seq":199,"ms":69058,"kind":"key","payload":{"kind":"down","key":"S","character":"s","deferred":true,"handler":"ignored"}}
{"seq":200,"ms":69059,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 namas","sel":[18,18],"composing":[13,18]}}
{"seq":201,"ms":69059,"kind":"diff","payload":{"start":17,"deleted":0,"inserted":"s"}}
{"seq":202,"ms":69059,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 nama","inserted":"s","at":17,"sel":[18,18],"composing":[13,18]}}}
{"seq":203,"ms":69136,"kind":"key","payload":{"kind":"up","key":"S","character":null,"deferred":false,"handler":"ignored"}}
{"seq":204,"ms":69270,"kind":"key","payload":{"kind":"down","key":"T","character":"t","deferred":true,"handler":"ignored"}}
{"seq":205,"ms":69271,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 namast","sel":[19,19],"composing":[13,19]}}
{"seq":206,"ms":69271,"kind":"diff","payload":{"start":18,"deleted":0,"inserted":"t"}}
{"seq":207,"ms":69271,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 namas","inserted":"t","at":18,"sel":[19,19],"composing":[13,19]}}}
{"seq":208,"ms":69445,"kind":"key","payload":{"kind":"down","key":"E","character":"e","deferred":true,"handler":"ignored"}}
{"seq":209,"ms":69446,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 namaste","sel":[20,20],"composing":[13,20]}}
{"seq":210,"ms":69446,"kind":"diff","payload":{"start":19,"deleted":0,"inserted":"e"}}
{"seq":211,"ms":69446,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 namast","inserted":"e","at":19,"sel":[20,20],"composing":[13,20]}}}
{"seq":212,"ms":69483,"kind":"key","payload":{"kind":"up","key":"T","character":null,"deferred":false,"handler":"ignored"}}
{"seq":213,"ms":69541,"kind":"key","payload":{"kind":"up","key":"E","character":null,"deferred":false,"handler":"ignored"}}
{"seq":214,"ms":70374,"kind":"key","payload":{"kind":"down","key":" ","character":" ","deferred":true,"handler":"ignored"}}
{"seq":215,"ms":70392,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते ","sel":[20,20],"composing":[13,20]}}
{"seq":216,"ms":70392,"kind":"diff","payload":{"start":13,"deleted":7,"inserted":"नमस्ते "}}
{"seq":217,"ms":70392,"kind":"synthesized","payload":{"delta":{"type":"replacement","oldText":". 안녕 한글 你好中国 namaste","replaced":[13,20],"text":"नमस्ते ","sel":[20,20],"composing":[13,20]}}}
{"seq":218,"ms":70423,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते ","sel":[20,20],"composing":null}}
{"seq":219,"ms":70423,"kind":"diff","payload":{"result":null}}
{"seq":220,"ms":70423,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好中国 नमस्ते ","sel":[20,20],"composing":null}}}
{"seq":221,"ms":70423,"kind":"commitKeySuppressionArmed","payload":{}}
{"seq":222,"ms":70453,"kind":"key","payload":{"kind":"up","key":" ","character":null,"deferred":false,"handler":"ignored"}}
{"seq":223,"ms":75927,"kind":"key","payload":{"kind":"down","key":"H","character":"h","deferred":false,"handler":"ignored"}}
{"seq":224,"ms":75928,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते h","sel":[21,21],"composing":[20,21]}}
{"seq":225,"ms":75928,"kind":"diff","payload":{"start":20,"deleted":0,"inserted":"h"}}
{"seq":226,"ms":75928,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 नमस्ते ","inserted":"h","at":20,"sel":[21,21],"composing":[20,21]}}}
{"seq":227,"ms":75928,"kind":"commitKeySuppressionDisarmed","payload":{"reason":"subsequentSnapshot"}}
{"seq":228,"ms":75974,"kind":"key","payload":{"kind":"up","key":"H","character":null,"deferred":false,"handler":"ignored"}}
{"seq":229,"ms":76058,"kind":"key","payload":{"kind":"down","key":"I","character":"i","deferred":true,"handler":"ignored"}}
{"seq":230,"ms":76059,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते hi","sel":[22,22],"composing":[20,22]}}
{"seq":231,"ms":76059,"kind":"diff","payload":{"start":21,"deleted":0,"inserted":"i"}}
{"seq":232,"ms":76059,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 नमस्ते h","inserted":"i","at":21,"sel":[22,22],"composing":[20,22]}}}
{"seq":233,"ms":76132,"kind":"key","payload":{"kind":"up","key":"I","character":null,"deferred":false,"handler":"ignored"}}
{"seq":234,"ms":76203,"kind":"key","payload":{"kind":"down","key":"N","character":"n","deferred":true,"handler":"ignored"}}
{"seq":235,"ms":76204,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते hin","sel":[23,23],"composing":[20,23]}}
{"seq":236,"ms":76204,"kind":"diff","payload":{"start":22,"deleted":0,"inserted":"n"}}
{"seq":237,"ms":76204,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 नमस्ते hi","inserted":"n","at":22,"sel":[23,23],"composing":[20,23]}}}
{"seq":238,"ms":76255,"kind":"key","payload":{"kind":"up","key":"N","character":null,"deferred":false,"handler":"ignored"}}
{"seq":239,"ms":76307,"kind":"key","payload":{"kind":"down","key":"D","character":"d","deferred":true,"handler":"ignored"}}
{"seq":240,"ms":76308,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते hind","sel":[24,24],"composing":[20,24]}}
{"seq":241,"ms":76308,"kind":"diff","payload":{"start":23,"deleted":0,"inserted":"d"}}
{"seq":242,"ms":76308,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 नमस्ते hin","inserted":"d","at":23,"sel":[24,24],"composing":[20,24]}}}
{"seq":243,"ms":76349,"kind":"key","payload":{"kind":"up","key":"D","character":null,"deferred":false,"handler":"ignored"}}
{"seq":244,"ms":76391,"kind":"key","payload":{"kind":"down","key":"I","character":"i","deferred":true,"handler":"ignored"}}
{"seq":245,"ms":76391,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते hindi","sel":[25,25],"composing":[20,25]}}
{"seq":246,"ms":76391,"kind":"diff","payload":{"start":24,"deleted":0,"inserted":"i"}}
{"seq":247,"ms":76392,"kind":"synthesized","payload":{"delta":{"type":"insertion","oldText":". 안녕 한글 你好中国 नमस्ते hind","inserted":"i","at":24,"sel":[25,25],"composing":[20,25]}}}
{"seq":248,"ms":76439,"kind":"key","payload":{"kind":"up","key":"I","character":null,"deferred":false,"handler":"ignored"}}
{"seq":249,"ms":76723,"kind":"key","payload":{"kind":"down","key":" ","character":" ","deferred":true,"handler":"ignored"}}
{"seq":250,"ms":76726,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते हिंदी ","sel":[26,26],"composing":[20,26]}}
{"seq":251,"ms":76726,"kind":"diff","payload":{"start":20,"deleted":5,"inserted":"हिंदी "}}
{"seq":252,"ms":76726,"kind":"synthesized","payload":{"delta":{"type":"replacement","oldText":". 안녕 한글 你好中国 नमस्ते hindi","replaced":[20,25],"text":"हिंदी ","sel":[26,26],"composing":[20,26]}}}
{"seq":253,"ms":76764,"kind":"snapshot","payload":{"text":". 안녕 한글 你好中国 नमस्ते हिंदी ","sel":[26,26],"composing":null}}
{"seq":254,"ms":76764,"kind":"diff","payload":{"result":null}}
{"seq":255,"ms":76764,"kind":"synthesized","payload":{"delta":{"type":"nonText","oldText":". 안녕 한글 你好中国 नमस्ते हिंदी ","sel":[26,26],"composing":null}}}
{"seq":256,"ms":76764,"kind":"commitKeySuppressionArmed","payload":{}}
{"seq":257,"ms":76801,"kind":"key","payload":{"kind":"up","key":" ","character":null,"deferred":false,"handler":"ignored"}}
''';

  test('Chrome multi-language session: Korean → Chinese Pinyin → Hindi '
      'across IME switches in a single block', () {
    final controller = EditorController(
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
