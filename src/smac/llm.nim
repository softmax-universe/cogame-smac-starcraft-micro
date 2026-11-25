## LLM-backed unit command. A policy is just a prompt: the game server
## composes the seat's view plus that seat's PLAYER_PROMPT and asks the model
## what its unit does for the next 5.0 seconds.
##
## This is a SIMULTANEOUS-decision game, so ALL LLM seats' calls go out as
## ONE parallel batch per turn (`curly.makeRequests`).
##
## Transports, in order of preference:
##   COWORLD_LLM_ENDPOINT (hosted/local native sidecar)
##   ANTHROPIC_API_KEY    (direct local development)
## With neither set, the client disables itself (`disabled = true`) and any
## LLM seat fails closed as a terminal policy failure.

import
  std/[json, os, strutils, unicode],
  curly,
  crunchy,
  sim_types, directives, prompts

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"

type
  LlmTransport* = enum
    ltNone, ltSidecar, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    sidecarEndpoint: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    throttled*: bool

  LlmError* = object of ValueError

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: (if config.model.len > 0: config.model
            else: "claude-haiku-4-5-20251001"),
    maxOutputTokens: max(1, config.maxOutputTokens)
  )
  let sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip()
  if sidecarEndpoint.len > 0:
    result.transport = ltSidecar
    result.sidecarEndpoint = sidecarEndpoint.strip(chars = {'/'}, leading = false)
    result.model = getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
    result.curl = newCurly()
    return
  result.apiKey = getEnv("ANTHROPIC_API_KEY").strip()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    stderr.writeLine "smac llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    stderr.writeLine "smac llm: no endpoint or credentials — the LLM provider is unavailable"

proc requestFor*(
  client: LlmClient, system, user: string, slot: int
): tuple[url: string, headers: HttpHeaders, body: string] =
  ## One Messages-API request, shaped for whichever transport is live.
  var body = %*{
    "model": client.model,
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  headers["anthropic-version"] = AnthropicVersion
  if client.transport == ltSidecar:
    if slot >= 0:
      headers["X-Coworld-Player-Slot"] = $slot
    result.url = client.sidecarEndpoint & "/v1/messages"
  else:
    headers["x-api-key"] = client.apiKey
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf*(
  client: LlmClient, response: Response, error, url: string
): string =
  ## The text of one batched reply, or an LlmError describing why there is
  ## none.
  if error.len > 0:
    raise newException(LlmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    client.disabled = true
    raise newException(
      LlmError, "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    client.throttled = true
    raise newException(LlmError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LlmError, "llm error " & $response.code & ": " &
      response.body.truncateRunes(MaxFallbackDetailRunes))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "llm refusal")
  if not payload.hasKey("content") or payload["content"].kind != JArray:
    raise newException(LlmError, "llm reply missing content array")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "reply cut off at max_tokens before any " &
      "JSON: " & result.truncateRunes(160).replace("\n", " "))

const
  StrategyRules = """FOCUS FIRE IS THE WHOLE GAME. Five units shooting five different enemies kill
nothing; five units on ONE enemy kill it in about three seconds, and a dead
enemy stops shooting back forever. Every enemy carries a numeric id: name it in
"target_id" and say it out loud so the others pick the same one.
KITING: a ranger out-ranges a blade six to one but is slower. Backing away
while your weapon is on cooldown wins free damage - until you run out of arena.
SCREENING: a blade standing between the enemy and a ranger buys that ranger the
seconds it needs. A dead ranger deals no damage for the rest of the battle.
"""
  ReplyRules = """Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
Schema:
{"note":"<=160 chars","cogs":[{"id":"<your own id>",
  "intent":"focus|attack_move|kite|hold|screen|retreat|regroup",
  "target_id":<enemy id> or null,
  "target":[x,y],
  "face":[x,y] or null,
  "say":"<=10 chars"}]}
Intents: focus = attack the enemy named by target_id (a ranger holds 300 pixels
off it, a blade closes to touching range); attack_move = advance to `target`
and attack whatever comes into range on the way; kite = attack the nearest
enemy while backing off to 340 pixels, standing still only to fire (rangers
only; a blade reads it as focus); hold = stand at `target` and fire at anything
in range; screen = put yourself 90 pixels in front of the most wounded friendly
ranger, between it and the nearest enemy; retreat = walk to `target` and do not
fire; regroup = move to the middle of your surviving squadmates.
`face` biases your aim. `say` is SHOUTED and every nearby squadmate hears it.
"""
  UnitRules = """RANGER: range 380 pixels, 4 damage per shot, 0.75-second cooldown, 60 health, 66 pixels/second. BLADE: reach 56 pixels in a 90-degree wedge, 10 damage per swing, 1.25-second cooldown, 120 health, 76 pixels/second. A blade is faster than a ranger and kills a full-health ranger in about 7.5 seconds of contact. Enemy units have the same weapons, select the closest visible friendly unit, and advance on it until it dies.
"""
  CanonicalSystemPrompt* = """
You command ONE unit in a five-unit squad fighting a scripted enemy army in a
top-down arena 1235 by 659 pixels. Your whole squad shares ONE score: how much
of the enemy army you destroy, whether you wipe it out, and how much of your
own health survives. Personal kills are worth almost nothing.
RANGER: you shoot. Range 380 pixels, 4 damage, one shot every 0.75 seconds, 60
health, 66 pixels per second. A blade kills a full-health ranger in about 7.5 seconds of contact.
BLADE: you swing. Reach 56 pixels in a 90-degree wedge, 10 damage, one swing
every 1.25 seconds, 120 health, 76 pixels per second - faster than a ranger.
The enemy has the same weapons. Enemy units pick the closest of you they can
see and walk at it until it dies.
FOCUS FIRE IS THE WHOLE GAME. Five units shooting five different enemies kill
nothing; five units on ONE enemy kill it in about three seconds, and a dead
enemy stops shooting back forever. Every enemy carries a numeric id: name it in
"target_id" and say it out loud so the others pick the same one.
KITING: a ranger out-ranges a blade six to one but is slower. Backing away
while your weapon is on cooldown wins free damage - until you run out of arena.
SCREENING: a blade standing between the enemy and a ranger buys that ranger the
seconds it needs. A dead ranger deals no damage for the rest of the battle.
Every 5 seconds you issue ONE order for yourself. A deterministic controller
executes it for the next 5 seconds: it walks you where you asked around walls,
turns you to face what you asked, and pulls the trigger when the shot will
land. You never control motors or the trigger directly.
You can see the whole board: every unit, its health, what each enemy is walking
at, and how many of you are already shooting it. You cannot see what your
squadmates are deciding THIS turn - all five of you decide at the same moment -
so use "say" to call your target.
Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
Schema:
{"note":"<=160 chars","cogs":[{"id":"<your own id>",
  "intent":"focus|attack_move|kite|hold|screen|retreat|regroup",
  "target_id":<enemy id> or null,
  "target":[x,y],
  "face":[x,y] or null,
  "say":"<=10 chars"}]}
Intents: focus = attack the enemy named by target_id (a ranger holds 300 pixels
off it, a blade closes to touching range); attack_move = advance to `target`
and attack whatever comes into range on the way; kite = attack the nearest
enemy while backing off to 340 pixels, standing still only to fire (rangers
only; a blade reads it as focus); hold = stand at `target` and fire at anything
in range; screen = put yourself 90 pixels in front of the most wounded friendly
ranger, between it and the nearest enemy; retreat = walk to `target` and do not
fire; regroup = move to the middle of your surviving squadmates.
`face` biases your aim. `say` is SHOUTED and every nearby squadmate hears it.
"""

proc systemPrompt*(selection: PromptSelection): string =
  case selection.selectedVariant
  of pvCanonical: CanonicalSystemPrompt
  of pvPlain:
    """You control one unit in a five-unit squad facing a scripted army on a top-down 1235 by 659 pixel board. The squad shares its score: enemy damage and elimination, and surviving friendly health. Personal kills contribute almost nothing.
Every 5 seconds choose one order for your unit. A deterministic controller carries it out for the following 5 seconds, navigating walls, orienting your unit, and firing when the shot will land. You do not command motors or the trigger.
You see every unit, its health, enemy targets, and how many friendlies target each enemy. The five seats decide simultaneously, so their current choices are hidden. Use say to announce your target.
""" & UnitRules & StrategyRules & ReplyRules
  of pvNumbered:
    """1. Command: one unit out of five, against a scripted enemy army in a top-down 1235 by 659 pixel arena.
2. Objective: one squad score rewards enemy damage, wiping out the enemy, and health retained by your squad. Personal kills are worth almost nothing.
3. Orders: every 5 seconds issue one order for yourself. The deterministic controller executes it for 5 seconds, walking around walls, turning toward your requested direction, and firing when a shot will land. Motors and trigger are not direct controls.
4. Information: all units and health are visible, together with enemy targets and the friendly count attacking each enemy. Simultaneous decisions hide your partners' current choices; announce your target with say.
""" & UnitRules & StrategyRules & ReplyRules
  of pvQuestions:
    """What do you command? One unit in a squad of five, fighting a scripted army in a 1235 by 659 pixel top-down arena.
What earns score? The whole squad shares credit for damaging and eliminating enemies and preserving friendly health. Personal kills are almost worthless.
How do you act? Submit one order every 5 seconds. A deterministic controller executes it for the next 5 seconds: wall navigation, facing, and firing when a shot will land. You cannot drive motors or pull the trigger yourself.
What can you see? All units, their health, enemy targets, and the number of friendlies shooting each target. You cannot see partners' simultaneous choices this turn. Call your target through say.
""" & UnitRules & StrategyRules & ReplyRules
  of pvReordered:
    """The whole board is visible: units, health, enemy targets, and friendly attackers per enemy. Current squadmate decisions are hidden because all five decide simultaneously. Use say to coordinate targets.
One order lasts 5 seconds, with a new order every 5 seconds. A deterministic controller navigates walls, faces the requested direction, and fires when the shot will land; motors and trigger are not directly controlled.
You command one of five units against a scripted army on a 1235 by 659 pixel top-down board. Your shared squad score rewards destroying enemies, wiping out their army, and retaining friendly health. Personal kills carry almost no value.
""" & UnitRules & StrategyRules & ReplyRules
  of pvHeldoutBriefing:
    """Command briefing: take one unit of a five-unit squad against a scripted army. The arena is top-down, 1235 by 659 pixels. Success is shared: enemy damage, enemy elimination, and surviving squad health determine the squad score; personal kills matter almost nothing.
Send one order on each 5-second decision boundary. The deterministic controller handles the next 5 seconds of wall avoidance, facing, and firing when a shot will land. Direct motor and trigger commands are unavailable.
Your view covers all units, health, enemy targets, and friendly attack counts. Partners decide at the same time, so their current decisions are unavailable. Announce the enemy you target using say.
""" & UnitRules & StrategyRules & ReplyRules
  of pvHeldoutReference:
    """Command assignment: one unit; squad size: five; opponent: scripted army; arena: top-down, 1235 by 659 pixels.
Score ownership: shared squad score. Components: enemy damage, complete enemy elimination, and friendly health remaining. Personal kills: almost no value.
Decision period and execution interval: 5 seconds each. Command: one order for your unit. Executor: deterministic wall navigation, requested facing, and firing when a shot will land. Direct motor/trigger access: none.
Visible state: all units and health, enemy targets, and friendly attackers per target. Hidden state: squadmates' simultaneous current decisions. Coordination: call targets with say.
""" & UnitRules & StrategyRules & ReplyRules
  of pvMixed: raise newException(ValueError, "mixed wording must be resolved")

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  result = selection.selectionMetadata()
  result["system_sha256"] = %sha256(system).toHex
  result["user_sha256"] = %sha256(user).toHex

proc operatorBlock*(prompt: string): string =
  ## The seat's own PLAYER_PROMPT, under a heading that tells the model how
  ## much weight it carries. Never echoed into the replay or the results.
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" &
    prompt.truncateRunes(MaxPromptRunes) & "\n\n"

proc userMessage*(operatorPrompt: string, viewJson: string): string =
  ## The user message: the operator's guidance, a blank line, then the seat's
  ## view. The view is built server-side from the seat's fog (see decide.nim).
  operatorBlock(operatorPrompt) & viewJson

proc requestedModel*(client: LlmClient): string =
  client.model
