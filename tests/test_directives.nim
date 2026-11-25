## Strict directive parsing and rune-boundary UTF-8 safety.
import std/[json, unicode, unittest]
import smac_helpers

const
  Ids = @["RANGER-alpha"]
  Cogs = @[0]

proc parse(text: string): SquadDirective =
  parseSquadDirective(extractJsonObject(text), Ids, Cogs, 600, 330,
                      MapWidth - 1, MapHeight - 1)

suite "directives":
  test "valid canonical JSON object parses":
    let d = parse(
      """{"note":"go","cogs":[{"id":"RANGER-alpha","intent":"focus",""" &
      """"target_id":3,"target":[10,10],"face":[20,20],"say":"E3"}]}""")
    check d.orders.len == 1
    check d.orders[0].fromReply
    check d.orders[0].intent == intFocus
    check d.orders[0].targetId == 3
    check d.orders[0].targetX == 10
    check d.orders[0].targetY == 10
    check d.orders[0].hasFace
    check d.orders[0].faceX == 20
    check d.orders[0].faceY == 20
    check d.orders[0].say == "E3"
    check d.source == dsLlm

  test "clean fenced JSON object parses; prose-prefixed and non-JSON are rejected":
    let fenced = parse("```json\n" &
      """{"note":"go","cogs":[{"id":"RANGER-alpha","intent":"focus","target_id":3}]}""" &
      "\n```")
    check fenced.orders[0].targetId == 3
    expect DirectiveError:
      discard parse("Sure! Here you go:\n```json\n" &
        """{"note":"go","cogs":[{"id":"RANGER-alpha","intent":"focus"}]}""" & "\n```")
    expect DirectiveError:
      discard parse("""thinking... {"note":"n","cogs":[{"id":"RANGER-alpha","intent":"focus"}]}""")
    expect DirectiveError:
      discard parse("no json at all here")

  test "alternate cogs object representation is rejected":
    expect DirectiveError:
      discard parse("""{"cogs":{"RANGER-alpha":{"intent":"kite","target_id":2}}}""")

  test "unknown, missing, and aliased intents are rejected":
    expect DirectiveError:
      discard parse("""{"cogs":[{"id":"RANGER-alpha","intent":"ATTACK-MOVE"}]}""")
    expect DirectiveError:
      discard parse("""{"cogs":[{"id":"RANGER-alpha","intent":"nonsense"}]}""")
    expect DirectiveError:
      discard parse("""{"cogs":[{"id":"RANGER-alpha"}]}""")

  test "target_id accepts integer or null and rejects string/float shims":
    check readTargetId(%3) == 3
    check readTargetId(newJNull()) == -1
    expect DirectiveError:
      discard readTargetId(%"E3")
    expect DirectiveError:
      discard readTargetId(%"7")
    expect DirectiveError:
      discard readTargetId(%3.0)
    expect DirectiveError:
      discard readTargetId(%"nonsense")

  test "an off-map target is clamped, null takes default, malformed rejects":
    let far = parse("""{"cogs":[{"id":"RANGER-alpha","intent":"focus","target":[99999,-4]}]}""")
    check far.orders[0].targetX == MapWidth - 1
    check far.orders[0].targetY == 0
    let none = parse("""{"cogs":[{"id":"RANGER-alpha","intent":"focus"}]}""")
    check none.orders[0].targetX == 600
    check none.orders[0].targetY == 330
    expect DirectiveError:
      discard parse("""{"cogs":[{"id":"RANGER-alpha","intent":"focus","target":{"x":10,"y":20}}]}""")

  test "extra cogs, wrong id, or empty cogs are rejected":
    expect DirectiveError:
      discard parse("""{"cogs":[{"id":"RANGER-alpha","intent":"focus"},{"id":"BLADE-alpha","intent":"focus"}]}""")
    expect DirectiveError:
      discard parse("""{"cogs":[{"id":"BLADE-gamma","intent":"hold"}]}""")
    expect DirectiveError:
      discard parse("""{"note":"n","cogs":[{"id":"NOT-A-SEAT","intent":"kite","target_id":5,"say":"E5"}]}""")
    for text in ["""{"note":"nothing to say","cogs":[]}""",
                 """{"note":"nothing to say"}""",
                 """{"note":"nothing to say","cogs":["E3"]}"""]:
      expect DirectiveError:
        discard parse(text)

  test "exact matching handles full-length unit aliases":
    check MaxCogIdRunes == 16
    check "RANGER-epsilon".runeLen <= MaxCogIdRunes
    let pair = parseSquadDirective(
      extractJsonObject(
        """{"cogs":[{"id":"RANGER-epsilon","intent":"hold"},""" &
        """{"id":"BLADE-alpha","intent":"kite"}]}"""),
      @["BLADE-alpha", "RANGER-epsilon"], @[2, 4],
      600, 330, MapWidth - 1, MapHeight - 1)
    check pair.orders[0].intent == intKite
    check pair.orders[1].intent == intHold

  test "a 300-character note is cut to 160 runes":
    var long = ""
    for _ in 0 ..< 300:
      long.add('x')
    let d = parse("""{"note":"""" & long & """","cogs":[{"id":"RANGER-alpha","intent":"focus"}]}""")
    check d.note.runeLen == MaxNoteRunes

  test "a say whose 10th and 11th characters are a 4-byte emoji cuts on a rune":
    let say = "abcdefghi\u{1F600}\u{1F600}"
    check say.runeLen == 11
    let cut = say.truncateRunes(MaxSayRunes)
    check cut.runeLen == MaxSayRunes
    check cut.validateUtf8() == -1
    let sanitized = sanitizeSay(say)
    check sanitized.validateUtf8() == -1
    check sanitized.runeLen <= MaxSayRunes
    let record = $(%*{"say": cut})
    check parseJson(record)["say"].getStr() == cut

  test "the serialized directive record stays inside MaxDirectiveRunes":
    var directive = SquadDirective(source: dsLlm)
    var long = ""
    for _ in 0 ..< 400:
      long.add("\u{1F600}")
    directive.note = long
    directive.orders = @[CogOrder(cogIndex: 0, id: "RANGER-alpha",
                                  intent: intFocus, targetId: 3,
                                  targetX: 10, targetY: 10, say: "E3")]
    let record = directive.boundedDirectiveRecord(1, 0, 0, "RANGER-alpha", "ranger")
    check record.runeLen <= MaxDirectiveRunes
    check record.validateUtf8() == -1
    check parseJson(record)["k"].getStr() == "directive"
