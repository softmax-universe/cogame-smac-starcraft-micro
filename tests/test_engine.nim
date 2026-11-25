## The turn loop: parallel batching for LLM seats, explicit scripted baselines,
## and fail-closed policy failure with no fabricated substitute moves.
import std/[json, os, strutils, unittest]
import smac_helpers

suite "engine":
  setup:
    delEnv("COWORLD_LLM_ENDPOINT")
    delEnv("COWORLD_LLM_MODEL")
    delEnv("ANTHROPIC_API_KEY")

  test "the engine seats one policy per unit and defaults to focusfire":
    var sim = newMicroSim()
    var engine = initDecisionEngine(sim)
    check engine.seats.len == 5
    for seat in 0 ..< 5:
      check engine.seats[seat].baseline == blFocusFire
      check engine.policyKind(seat) == "scripted"
      check sim.commandedCogs(seat) == @[seat]

  test "explicit scripted seats run deterministically without LLM credentials":
    var sim = newMicroSim()
    var engine = initDecisionEngine(sim)
    check engine.client.disabled
    let records = engine.turn(sim, 0, 12, 0)
    check not engine.failed
    for seat in 0 ..< 5:
      check engine.haveDirective[seat]
      check engine.directives[seat].source == dsScripted
      check engine.directives[seat].orders.len == 1
      check engine.directives[seat].orders[0].cogIndex == seat
    check records.len == 0

  test "an LLM seat with no endpoint/credentials fails closed with no substitute move":
    var sim = newMicroSim()
    var engine = initDecisionEngine(sim)
    engine.seats[0].isLlm = true
    engine.seats[0].prompt = "focus fire"
    let records = engine.turn(sim, 0, 12, 0)
    check engine.failed
    check engine.failedSeat == 0
    check engine.failureCause == "no_credentials"
    check not engine.haveDirective[0]
    var causes: seq[string]
    for record in records:
      let node = parseJson(record)
      if node["k"].getStr() == "fallback":
        causes.add(node["cause"].getStr())
        check node["seat"].getInt() == 0
        check node.hasKey("battle")
    check causes == @["no_credentials"]

  test "the budget guard fails closed for LLM seats instead of substituting a baseline":
    var sim = newMicroSim()
    var engine = initDecisionEngine(sim)
    engine.seats[0].isLlm = true
    engine.seats[0].prompt = "focus fire"
    let records = engine.turn(sim, 1, 12, sim.config.wallClockBudgetSeconds - 5)
    check engine.llmOff
    check engine.failed
    check engine.failedSeat == 0
    check engine.failureCause == "budget_guard"
    check not engine.haveDirective[0]
    var guarded = false
    for record in records:
      if parseJson(record)["k"].getStr() == "budget_guard":
        guarded = true
    check guarded

  test "turnSpacingMs holds five seats under the sidecar's 30 req/min cap":
    let config = microConfig(microConfigJson())
    check 5 * 60 div (DefaultTurnSpacingMs div 1000) <= 30
    check config.attempt1Ms + config.retryMs <= config.turnBudgetMs
    check config.attempt1Ms mod 1000 == 0
    check config.retryMs mod 1000 == 0

  test "explicit scripted seats produce legal directives on every tick":
    var
      sim = newMicroSim(microConfigJson(maxTicks = 240))
      engine = initDecisionEngine(sim)
      ctl = initControlState(sim)
      prev = sim.idle()
    discard engine.turn(sim, 0, 12, 0)
    check not engine.failed
    for tick in 0 ..< 120:
      ctl.observeEnemies(sim)
      var now = sim.idle()
      for seat in 0 ..< sim.config.friendlyCount():
        check engine.haveDirective[seat]
        let orders = engine.directives[seat].orders
        check orders.len == 1
        now[seat] = decodeInputMask(ctl.compileMask(sim, orders[0], seat))
      sim.step(now, prev)
      prev = now
      if sim.phase != Playing:
        break

  test "focusfire baseline emits a legal scripted directive":
    var sim = newMicroSim()
    var engine = initDecisionEngine(sim)
    let directive = engine.focusfireFor(sim, @[3])
    check directive.orders.len == 1
    check directive.orders[0].cogIndex == 3
    check directive.source == dsScripted

  test "the system prompt demands a reply beginning with a brace":
    check "MUST begin with '{'" in CanonicalSystemPrompt
    check "target_id" in CanonicalSystemPrompt
    check "focus|attack_move|kite|hold|screen|retreat|regroup" in CanonicalSystemPrompt

  test "decide.nim contains no fabricated fallback move helpers":
    let src = readFile(GameDir / "src/smac/decide.nim")
    check "holdFallbackDirective" notin src
    check "repairMissingOrders" notin src
