## The directive schema: what a commander (LLM or scripted) may say, how a
## reply is parsed TOLERANTLY, and how an illegal reply is repaired instead of
## rejected.
##
## Both policy kinds emit the SAME object, so the two are strictly comparable
## and one validator covers both — that is what makes the bounded-orders test
## in tests/test_control.nim meaningful.
##
## RUNE DISCIPLINE. Every cap in this file is measured in RUNES (Unicode
## codepoints) and every truncation lands on a rune boundary (`runeLen` /
## `runeSubStr`). Slicing a string by BYTE index anywhere on the path to the
## replay is forbidden: a byte-truncated multi-byte character renders fine in a
## browser and then fails a strict UTF-8 parser, which is exactly the class of
## bug that makes a replay unreadable to everything except the one viewer that
## happened to be lenient.

import
  std/[json, strutils, unicode],
  sim_types

type
  Intent* = enum
    ## What a unit is being told to do for the next turn. A closed enum: an
    ## unrecognised intent is repaired to `intFocus`, never dropped, so a unit
    ## is never left unactuated.
    intFocus = "focus"
    intAttackMove = "attack_move"
    intKite = "kite"
    intHold = "hold"
    intScreen = "screen"
    intRetreat = "retreat"
    intRegroup = "regroup"

  CogOrder* = object
    ## One commanded cog's orders for the next turn.
    cogIndex*: int             ## the live unit this order drives.
    id*: string                ## the unit's anonymous alias, "RANGER-alpha".
    intent*: Intent
    targetId*: int             ## the enemy id this order names ("E3" -> 3), or
                               ## -1 when the reply named none. Resolved to a
                               ## LIVING enemy by the control layer.
    targetX*, targetY*: int    ## clamped into the map box.
    hasFace*: bool
    faceX*, faceY*: int
    say*: string               ## <= MaxSayRunes, sanitized; becomes a SHOUT.
    fromReply*: bool           ## a reply entry really named this cog. False
                               ## means the parser filled it in, and the
                               ## caller repairs it from last turn's directive
                               ## (else `focusfire`'s) — never from a default.

  DirectiveSource* = enum
    dsLlm = "llm"
    dsScripted = "scripted"
    dsFallback = "fallback"

  SquadDirective* = object
    ## One seat's whole order set for one turn.
    note*: string              ## <= MaxNoteRunes; the commander's own line.
    orders*: seq[CogOrder]
    source*: DirectiveSource
    latencyMs*: int

  DirectiveError* = object of ValueError

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single
  ## place any recorded string is shortened.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc sanitizeSay*(text: string): string =
  ## A cog's shout: capped at MaxSayRunes on a rune boundary FIRST, then run
  ## through the starter's printable-ASCII shout sanitiser. Doing it in that
  ## order means the rune cut never leaves half a codepoint for the ASCII
  ## filter to smear.
  result = ""
  for rune in text.truncateRunes(MaxSayRunes).runes:
    let value = int(rune)
    # Braces are excluded deliberately: the replay chat stream carries the
    # micro CONTROL records as JSON objects and tells them apart from a
    # cog's shout by a leading '{'. A shout that could start with one would
    # make that discrimination ambiguous.
    if value >= 32 and value < 127 and value != ord('{') and
        value != ord('}'):
      result.add($rune)
  result = result.strip()

proc sanitizeNote*(text: string): string =
  ## The commander's own line, as it reaches the replay and the match feed.
  ## Newlines collapse to spaces so one record stays one line.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(MaxNoteRunes)

proc parseIntent*(text: string): Intent =
  ## Strict canonical intent parser. Unknown or empty intents raise
  ## DirectiveError rather than fabricating a move.
  let key = text.strip()
  for intent in Intent:
    if $intent == key:
      return intent
  raise newException(DirectiveError, "invalid intent: " & key.truncateRunes(32))

proc extractJsonObject*(text: string): JsonNode =
  ## Parses a single JSON object from a model reply, unwrapping a single outer
  ## markdown code fence if present. Rejects prose, non-JSON text, or
  ## non-object values with DirectiveError.
  var trimmed = text.strip()
  if trimmed.startsWith("```") and trimmed.endsWith("```") and trimmed.len >= 6:
    let nl = trimmed.find('\n')
    if nl > 0 and nl < trimmed.len - 3:
      trimmed = trimmed[nl + 1 ..< trimmed.len - 3].strip()
  if trimmed.len == 0 or trimmed[0] != '{':
    var head = trimmed
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(
      DirectiveError, "reply must be a JSON object starting with '{': " &
        head.replace("\n", " "))
  try:
    result = parseJson(trimmed)
  except CatchableError as e:
    raise newException(DirectiveError, "invalid JSON in reply: " & e.msg)
  if result.kind != JObject:
    raise newException(DirectiveError, "reply JSON must be an object")

proc readCoord(node: JsonNode): tuple[ok: bool, value: int] =
  if node.isNil:
    return (false, 0)
  case node.kind
  of JInt:
    (true, int(node.getBiggestInt()))
  of JFloat:
    let f = node.getFloat()
    if f != f or f > 1.0e9 or f < -1.0e9: (false, 0)
    else: (true, int(f))
  else:
    (false, 0)

proc readPoint(
  node: JsonNode, fieldName: string, defaultX, defaultY, maxX, maxY: int
): tuple[given: bool, x, y: int] =
  ## A `[x, y]` coordinate pair, clamped into the map box. Absent or null
  ## returns `given = false` with the caller's default; malformed values raise
  ## DirectiveError.
  if node.isNil or node.kind == JNull:
    return (false, defaultX, defaultY)
  if node.kind != JArray or node.len != 2:
    raise newException(DirectiveError, fieldName & " must be [x, y] or null")
  let
    rx = readCoord(node[0])
    ry = readCoord(node[1])
  if not rx.ok or not ry.ok:
    raise newException(DirectiveError, fieldName & " coordinates must be finite numbers")
  result = (
    true,
    clamp(rx.value, 0, max(0, maxX)),
    clamp(ry.value, 0, max(0, maxY))
  )

proc readTargetId*(node: JsonNode): int =
  ## The order's `target_id`: an integer enemy id or null (-1). Any other type
  ## raises DirectiveError.
  if node.isNil or node.kind == JNull:
    return -1
  if node.kind == JInt:
    return int(node.getBiggestInt())
  raise newException(DirectiveError, "target_id must be an integer or null")

proc parseSquadDirective*(
  payload: JsonNode,
  commandedIds: seq[string],
  commandedCogs: seq[int],
  defaultX, defaultY, maxX, maxY: int
): SquadDirective =
  ## Strictly parses one model reply into a legal SquadDirective.
  ## Rejects missing/extra cogs, mismatched ids, invalid intents, or malformed
  ## coordinate/target_id fields with DirectiveError rather than silently
  ## repairing or fabricating orders. Rune-boundary truncation is applied to
  ## `note` and `say` so replay records remain valid UTF-8.
  doAssert commandedIds.len == commandedCogs.len
  if payload.isNil or payload.kind != JObject:
    raise newException(DirectiveError, "directive payload must be a JSON object")
  if payload.hasKey("note") and payload["note"].kind != JNull:
    if payload["note"].kind != JString:
      raise newException(DirectiveError, "note must be a string or null")
    result.note = sanitizeNote(payload["note"].getStr())
  result.source = dsLlm
  if not payload.hasKey("cogs") or payload["cogs"].kind != JArray:
    raise newException(DirectiveError, "cogs must be a JSON array")
  let cogsNode = payload["cogs"]
  if cogsNode.len != commandedIds.len:
    raise newException(
      DirectiveError,
      "cogs must contain exactly " & $commandedIds.len & " entry(s), got " &
        $cogsNode.len)
  var
    claimed = newSeq[bool](commandedIds.len)
    orders = newSeq[CogOrder](commandedIds.len)
  for item in cogsNode:
    if item.kind != JObject:
      raise newException(DirectiveError, "each cogs entry must be a JSON object")
    if not item.hasKey("id") or item["id"].kind != JString:
      raise newException(DirectiveError, "cogs[].id must be a string")
    let rawId = item["id"].getStr().strip().truncateRunes(MaxCogIdRunes)
    var slot = -1
    for i, id in commandedIds:
      if not claimed[i] and id == rawId:
        slot = i
        break
    if slot < 0:
      raise newException(
        DirectiveError, "cogs[].id does not match commanded unit: " & rawId)
    if not item.hasKey("intent") or item["intent"].kind != JString:
      raise newException(DirectiveError, "cogs[].intent must be a string")
    let intent = parseIntent(item["intent"].getStr())
    let targetId = readTargetId(item{"target_id"})
    let target = readPoint(item{"target"}, "target", defaultX, defaultY, maxX, maxY)
    let face = readPoint(item{"face"}, "face", 0, 0, maxX, maxY)
    var say = ""
    if item.hasKey("say") and item["say"].kind != JNull:
      if item["say"].kind != JString:
        raise newException(DirectiveError, "cogs[].say must be a string or null")
      say = sanitizeSay(item["say"].getStr())
    claimed[slot] = true
    orders[slot] = CogOrder(
      cogIndex: commandedCogs[slot],
      id: commandedIds[slot],
      intent: intent,
      targetId: targetId,
      targetX: target.x,
      targetY: target.y,
      hasFace: face.given,
      faceX: face.x,
      faceY: face.y,
      say: say,
      fromReply: true
    )
  result.orders = orders

proc directiveRecord*(
  directive: SquadDirective,
  battle, turn, seat: int,
  alias, role: string
): JsonNode =
  ## The replay chat record for one turn's directive. Re-applied at playback
  ## into NON-HASHED sim fields only: it drives the broadcast feed and
  ## tools/replay_summary.py and can never affect the simulation.
  var cogs = newJArray()
  for order in directive.orders:
    var item = %*{
      "id": order.id,
      "intent": $order.intent,
      "target": [order.targetX, order.targetY],
      "say": order.say
    }
    if order.targetId > 0:
      item["target_id"] = %order.targetId
    else:
      item["target_id"] = newJNull()
    if order.hasFace:
      item["face"] = %[order.faceX, order.faceY]
    else:
      item["face"] = newJNull()
    cogs.add(item)
  %*{
    "k": "directive",
    "battle": battle,
    "turn": turn,
    "seat": seat,
    "alias": alias,
    "role": role,
    "source": $directive.source,
    "latency_ms": directive.latencyMs,
    "note": directive.note,
    "cogs": cogs
  }

proc boundedDirectiveRecord*(
  directive: SquadDirective,
  battle, turn, seat: int,
  alias, role: string
): string =
  ## The serialized directive record, guaranteed <= MaxDirectiveRunes. The
  ## note is the only unbounded-in-practice field, so it is the one that
  ## shrinks; the cut still lands on a rune boundary.
  var trimmed = directive
  result = $trimmed.directiveRecord(battle, turn, seat, alias, role)
  var guard = 0
  while result.runeLen > MaxDirectiveRunes and guard < 12:
    inc guard
    let keep = max(0, trimmed.note.runeLen - max(8, trimmed.note.runeLen div 2))
    trimmed.note = trimmed.note.truncateRunes(keep)
    for i in 0 ..< trimmed.orders.len:
      trimmed.orders[i].say = trimmed.orders[i].say.truncateRunes(
        max(0, trimmed.orders[i].say.runeLen - 2))
    result = $trimmed.directiveRecord(battle, turn, seat, alias, role)
  # The loop always converges: with an empty note and empty says the record is
  # a few hundred runes of fixed structure. Never cut the SERIALIZED string —
  # that would emit broken JSON, which is the exact failure the rune rule
  # exists to prevent.

proc actionJson*(directive: SquadDirective): JsonNode =
  ## The macro the controller receives, excluding spectator and transport metadata.
  var cogs = newJArray()
  for order in directive.orders:
    var item = %*{"id": order.id, "intent": $order.intent,
      "target": [order.targetX, order.targetY]}
    item["face"] = if order.hasFace: %[order.faceX, order.faceY] else: newJNull()
    item["target_id"] = if order.targetId > 0: %order.targetId else: newJNull()
    item["say"] = %order.say
    cogs.add(item)
  %*{"note": directive.note, "cogs": cogs}
