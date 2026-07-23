import std/[macros, macrocache, strformat, strutils, sequtils, algorithm, os, dynlib]

const
  StaticPlugins = CacheSeq"plugnim.static"
  DynamicPlugins = CacheSeq"plugnim.dynamic"
  PluginStates = CacheSeq"plugnim.states"
  ContextGenerated = CacheSeq"plugnim.contextGenerated"
  PlugnimDir = currentSourcePath().parentDir
  NimCompiler = getCurrentCompilerExe()
  DynlibExt = when defined(windows): ".dll" elif defined(macosx): ".dylib" else: ".so"
  contextSignatureSymbol = "plugnimContextSignature"
  plugnimPluginId {.strdefine.} = ""

const isDynamicPluginBuild* = plugnimPluginId.len > 0

func symbolName(pluginId, functionName: string): string = functionName & pluginId
func pointerName(pluginId, functionName: string): string = symbolName(pluginId, functionName) & "Pointer"
func stateVarName(pluginId, name: string): string = name & pluginId & "State"

proc pluginCacheDir(pluginId: string): string =
  getTempDir() / "plugnim" / pluginId

proc pluginLibPath(pluginId: string, version: int): string =
  pluginCacheDir(pluginId) / ("plugin." & $version & DynlibExt)

proc compileDynamicPlugin*(pluginId, sourceFile, outPath: string): bool =
  createDir outPath.parentDir
  let command = [
    quoteShell NimCompiler, "c", "--app:lib", "--hints:off", "--warning:UnusedImport:off",
    "--nimcache:" & quoteShell(outPath.changeFileExt("") & ".nimcache"),
    "-d:plugnimPluginId=" & pluginId,
    "--path:" & quoteShell(PlugnimDir),
    "--out:" & quoteShell(outPath),
    quoteShell sourceFile,
  ].join(" ")
  echo "plugnim: compiling plugin '", pluginId, "'"
  result = execShellCmd(command) == 0
  if not result:
    echo "plugnim: could not compile plugin '", pluginId, "' (see the nim errors above)."
    echo "         source: ", sourceFile
    echo "         if this was a reload, the previously loaded version stays active."

proc openPluginLib(path: string): LibHandle = loadLib(path)
proc closePluginLib(lib: LibHandle) =
  if not lib.isNil:
    unloadLib(lib)
proc pluginSymbol(lib: LibHandle, name: string): pointer = lib.symAddr(name)

proc pluginLibSignature*(lib: LibHandle): string =
  let symbol = lib.symAddr(contextSignatureSymbol)
  if symbol.isNil:
    return ""
  $cast[proc(): cstring {.cdecl.}](symbol)()

proc checkPluginSignature(pluginId: string, lib: LibHandle, expected: string): bool =
  let actual = pluginLibSignature(lib)
  if actual == expected:
    return true
  echo "plugnim: refusing to activate plugin '", pluginId, "'."
  echo "  Its shared-state contract changed since the host program was built. The host"
  echo "  and plugin must agree on the context layout, otherwise the plugin would read"
  echo "  and write the wrong fields and corrupt memory. Rebuild the host to adopt the"
  echo "  new contract; the previously loaded version stays active."
  echo "  host was built for: ", (if expected.len == 0: "(no shared state)" else: expected)
  echo "  plugin now expects: ", (if actual.len == 0: "(no shared state)" else: actual)

proc reportMissingFunction(pluginId, functionName: string) =
  echo "plugnim: refusing to activate plugin '", pluginId, "'."
  echo "  It no longer provides '", functionName, "', which the host program calls. A"
  echo "  reloaded plugin must keep every function the host was built against. The"
  echo "  previously loaded version stays active."

proc reportOpenFailure(pluginId, path: string) =
  echo "plugnim: compiled plugin '", pluginId, "' but could not open its library at ", path

func exported(name: string): NimNode = postfix(ident name, "*")
func ptrTo(name: string): NimNode = nnkPtrTy.newTree(ident name)

iterator pluginParams(procDef: NimNode): tuple[name: string, typ: NimNode] =
  let formalParams = procDef.params
  for i in 1 ..< formalParams.len:
    let defs = formalParams[i]
    for j in 0 ..< defs.len - 2:
      yield (defs[j].strVal, defs[^2])

proc extractOrder(procDef: NimNode): int =
  let pragmas = procDef.pragma
  if pragmas.kind != nnkPragma:
    return 0
  for i in 0 ..< pragmas.len:
    if pragmas[i].kind == nnkExprColonExpr and pragmas[i][0].eqIdent"order":
      let text = pragmas[i][1].repr
      try:
        result = parseInt(text)
      except ValueError:
        error "a plugin function's order must be an integer literal, e.g. {.order: -1.};\n" &
          "  got: " & text, pragmas[i][1]
      pragmas.del(i)
      break
  if pragmas.len == 0:
    procDef.pragma = newEmptyNode()

proc register(cache: CacheSeq, identifier, procDef: NimNode) =
  let order = extractOrder(procDef)
  cache.add nnkPar.newTree(
    newLit identifier.strVal,
    newLit identifier.lineInfoObj.filename,
    newLit order,
    procDef)

proc registerState(pluginId, name: string) =
  PluginStates.add nnkPar.newTree(newLit pluginId, newLit name)

proc pluginStateNames(pluginId: string): seq[string] =
  for entry in PluginStates:
    if entry[0].strVal == pluginId:
      result.add entry[1].strVal

iterator plugins(cache: CacheSeq): tuple[pluginId, functionName, file: string, order: int, def: NimNode] =
  for entry in cache:
    let def = entry[3]
    yield (entry[0].strVal, def.name.strVal, entry[1].strVal, int(entry[2].intVal), def)

iterator dynamicPluginFiles(): tuple[pluginId, file: string] =
  var seen: seq[string]
  for p in plugins(DynamicPlugins):
    if p.pluginId notin seen:
      seen.add p.pluginId
      yield (p.pluginId, p.file)

proc knownFunctionNames(): seq[string] =
  for p in plugins(StaticPlugins):
    result.add p.functionName
  for p in plugins(DynamicPlugins):
    result.add p.functionName
  result = result.deduplicate

proc contextFields(): seq[tuple[name: string, typ: NimNode, plugin: string]] =
  for p in plugins(DynamicPlugins):
    for (name, typ) in pluginParams(p.def):
      var known = false
      for existing in result:
        if existing.name == name:
          known = true
          if existing.typ.repr != typ.repr:
            error "dynamic plugins disagree on the type of shared state '" & name & "'.\n" &
              "  plugin '" & existing.plugin & "' declares it as " & existing.typ.repr & "\n" &
              "  plugin '" & p.pluginId & "' declares it as " & typ.repr & "\n" &
              "  All dynamic plugins share one context object, so each state name must have\n" &
              "  a single consistent type across every plugin.", typ
      if not known:
        result.add (name, typ, p.pluginId)

proc expectPluginBody(identifier, body: NimNode) =
  if identifier.kind != nnkIdent:
    error "a plugin needs a single name, e.g. `plugin Physics:`.\n  got: " & identifier.repr, identifier
  if body.kind != nnkStmtList:
    error "a plugin body must be an indented block of proc definitions.", body

proc expectPluginProc(identifier, node: NimNode) =
  if node.kind != nnkProcDef:
    error "plugin '" & identifier.strVal & "' may only contain `proc` definitions.\n" &
      "  this statement isn't a proc — move it outside the plugin block.", node

macro plugin*(identifier, body: untyped): untyped =
  expectPluginBody(identifier, body)
  result = newStmtList()
  for item in body:
    case item.kind
    of nnkProcDef:
      register(StaticPlugins, identifier, item)
      let emitted = copyNimTree(item)
      emitted.name = ident symbolName(identifier.strVal, item.name.strVal)
      result.add emitted
    of nnkVarSection, nnkLetSection:
      for def in item:
        for i in 0 ..< def.len - 2:
          let name = def[i].strVal
          registerState(identifier.strVal, name)
          result.add nnkVarSection.newTree(newIdentDefs(
            ident stateVarName(identifier.strVal, name),
            copyNimTree(def[^2]), copyNimTree(def[^1])))
    else:
      error "plugin '" & identifier.strVal & "' may only contain proc definitions and\n" &
        "  state declarations (`var`/`let`). Move anything else outside the plugin block.", item

macro plugin*(identifier, flag, body: untyped): untyped =
  if not flag.eqIdent"dynamic":
    error "unknown plugin flag '" & flag.repr & "'.\n" &
      "  the only supported flag is `dynamic`, as in `plugin Physics, dynamic:`.", flag
  expectPluginBody(identifier, body)
  for item in body:
    if item.kind in {nnkVarSection, nnkLetSection}:
      error "dynamic plugin '" & identifier.strVal & "' can't declare private state.\n" &
        "  Dynamic plugins share one context across the shared-library boundary, so there\n" &
        "  is nowhere to keep per-plugin state. Use a static plugin for private state.", item
    expectPluginProc(identifier, item)
    if item[2].kind != nnkEmpty:
      error "dynamic plugin function '" & item.name.strVal & "' can't be generic.\n" &
        "  its parameters must be concrete types so the shared context has a fixed layout.", item[2]
    if item.params[0].kind != nnkEmpty:
      error "dynamic plugin function '" & item.name.strVal & "' declares a return type.\n" &
        "  Dynamic plugins are called across a shared-library boundary through void function\n" &
        "  pointers, so they can't return a value. Communicate results through plugin state\n" &
        "  (a parameter), which becomes part of the generated context.", item.params[0]
    register(DynamicPlugins, identifier, item)
  result = newStmtList()

macro generatePluginContext*(): untyped =
  ContextGenerated.add newLit(true)
  let ctxFields = contextFields()

  var fields = nnkRecList.newTree()
  for field in ctxFields:
    fields.add newIdentDefs(exported field.name, copyNimTree(field.typ))

  let signature = newLit ctxFields.mapIt(it.name & ":" & it.typ.repr).join(";")

  result = newStmtList(nnkTypeSection.newTree(
    nnkTypeDef.newTree(exported"PluginContext", newEmptyNode(),
      nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), fields)),
    nnkTypeDef.newTree(exported"PluginFunction", newEmptyNode(),
      nnkProcTy.newTree(
        nnkFormalParams.newTree(newEmptyNode(), newIdentDefs(ident"context", ptrTo"PluginContext")),
        nnkPragma.newTree(ident"cdecl")))))

  result.add nnkConstSection.newTree(
    nnkConstDef.newTree(exported"pluginContextSignature", newEmptyNode(), signature))

  when plugnimPluginId.len > 0:
    let getter = ident contextSignatureSymbol
    result.add quote do:
      proc `getter`(): cstring {.exportc, dynlib, cdecl.} =
        pluginContextSignature.cstring
    let ctx = ident"plugnimContext"
    for p in plugins(DynamicPlugins):
      if p.pluginId != plugnimPluginId:
        continue
      var body = newStmtList()
      for (name, _) in pluginParams(p.def):
        let local = ident name
        body.add quote do:
          let `local` = `ctx`.`local`
      body.add copyNimTree(p.def.body)
      let sym = ident symbolName(p.pluginId, p.functionName)
      result.add quote do:
        proc `sym`(`ctx`: ptr PluginContext) {.exportc, dynlib, cdecl.} =
          `body`

macro loadDynamicPlugins*(): untyped =
  result = newStmtList()
  when plugnimPluginId.len == 0:
    if DynamicPlugins.len > 0 and ContextGenerated.len == 0:
      error "loadDynamicPlugins() was called before generatePluginContext().\n" &
        "  The shared context type must exist first. Call generatePluginContext() once,\n" &
        "  after all your `plugin ... dynamic:` blocks and before loadDynamicPlugins()."

    let
      compile = bindSym"compileDynamicPlugin"
      libPath = bindSym"pluginLibPath"
      openLib = bindSym"openPluginLib"
      closeLib = bindSym"closePluginLib"
      pluginSym = bindSym"pluginSymbol"
      checkSig = bindSym"checkPluginSignature"
      reportMissing = bindSym"reportMissingFunction"
      reportOpen = bindSym"reportOpenFailure"

    var reloadBranches: seq[NimNode]
    for (pluginId, file) in dynamicPluginFiles():
      let
        lib = genSym(nskVar, "lib")
        version = genSym(nskVar, "version")
        loadPlugin = genSym(nskProc, "loadPlugin")
        candidate = genSym(nskLet, "candidate")
        path = genSym(nskLet, "path")
        id = newLit pluginId
        src = newLit file

      var resolves = newStmtList()
      var assigns = newStmtList()
      for p in plugins(DynamicPlugins):
        if p.pluginId != pluginId:
          continue
        let fnPointer = ident pointerName(p.pluginId, p.functionName)
        let sym = newLit symbolName(p.pluginId, p.functionName)
        let fnName = newLit p.functionName
        let resolved = genSym(nskLet, "fn")
        result.add quote do:
          var `fnPointer`: PluginFunction
        resolves.add quote do:
          let `resolved` = `pluginSym`(`candidate`, `sym`)
          if `resolved`.isNil:
            `reportMissing`(`id`, `fnName`)
            `closeLib`(`candidate`)
            return false
        assigns.add quote do:
          `fnPointer` = cast[PluginFunction](`resolved`)

      result.add quote do:
        var `lib`: LibHandle
        var `version` = 0
        proc `loadPlugin`(): bool =
          let `path` = `libPath`(`id`, `version`)
          if not `compile`(`id`, `src`, `path`):
            return false
          let `candidate` = `openLib`(`path`)
          if `candidate`.isNil:
            `reportOpen`(`id`, `path`)
            return false
          if not `checkSig`(`id`, `candidate`, pluginContextSignature):
            `closeLib`(`candidate`)
            return false
          `resolves`
          `closeLib`(`lib`)
          `lib` = `candidate`
          `assigns`
          inc `version`
          true
        if not `loadPlugin`():
          quit "plugnim: could not load dynamic plugin '" & `id` & "' at startup."

      reloadBranches.add nnkOfBranch.newTree(id, quote do:
        discard `loadPlugin`())

    if reloadBranches.len > 0:
      var dispatch = nnkCaseStmt.newTree(ident"pluginId")
      for branch in reloadBranches:
        dispatch.add branch
      dispatch.add nnkElse.newTree(quote do:
        raise newException(ValueError, "plugnim: no dynamic plugin named '" & pluginId & "'"))
      result.add newProc(
        exported"reloadDynamicPlugin",
        [newEmptyNode(), newIdentDefs(ident"pluginId", ident"string")],
        newStmtList(dispatch))

macro generatePluginFunctionCalls*(functionName: untyped): untyped =
  if functionName.kind != nnkIdent:
    error "generatePluginFunctionCalls expects a plugin function name, " &
      "e.g. generatePluginFunctionCalls(update).", functionName
  result = newStmtList()
  when plugnimPluginId.len == 0:
    let wanted = functionName.strVal
    let known = knownFunctionNames()
    if wanted notin known:
      error "no plugin defines a function named '" & wanted & "'.\n" &
        "  known plugin functions: " & (if known.len == 0: "(none)" else: known.join(", ")), functionName

    let ctx = genSym(nskVar, "context")
    var calls: seq[tuple[order: int, call: NimNode]]
    var contextFieldNames: seq[string]
    var hasDynamic = false

    for p in plugins(StaticPlugins):
      if p.functionName != wanted:
        continue
      let states = pluginStateNames(p.pluginId)
      var call = newCall(ident symbolName(p.pluginId, p.functionName))
      var used: seq[string]
      for (name, _) in pluginParams(p.def):
        call.add ident(name)
        if name in states and name notin used:
          used.add name
      if used.len == 0:
        calls.add (p.order, call)
      else:
        var body = newStmtList()
        for name in used:
          let local = ident name
          let stateVar = ident stateVarName(p.pluginId, name)
          body.add quote do:
            var `local` = `stateVar`
        body.add call
        for name in used:
          let local = ident name
          let stateVar = ident stateVarName(p.pluginId, name)
          body.add quote do:
            `stateVar` = `local`
        calls.add (p.order, nnkBlockStmt.newTree(newEmptyNode(), body))

    for p in plugins(DynamicPlugins):
      if p.functionName != wanted:
        continue
      hasDynamic = true
      for (name, _) in pluginParams(p.def):
        if name notin contextFieldNames:
          contextFieldNames.add name
      let fnPointer = ident pointerName(p.pluginId, p.functionName)
      calls.add (p.order, newCall(fnPointer, newCall(ident"addr", ctx)))

    if hasDynamic and ContextGenerated.len == 0:
      error "generatePluginFunctionCalls(" & wanted & ") needs the plugin context, but\n" &
        "  generatePluginContext() has not been called yet. Call it once after your plugin\n" &
        "  blocks and before generating any calls."

    if hasDynamic:
      result.add quote do:
        var `ctx`: PluginContext
      for name in contextFieldNames:
        let local = ident name
        result.add newAssignment(newDotExpr(ctx, local), local)

    for entry in calls.sortedByIt(it.order):
      result.add entry.call

when isMainModule:
  plugin ABC:
    var banana = 42
    proc load {.order: 10.} =
      echo "ONE"
    proc chode(banana: int) =
      echo &"CHODE {banana}"
    proc update(dt: float) =
      discard

  plugin DEF, dynamic:
    proc load {.order: 9.} =
      echo "TWO"
    proc update(dt: float) =
      discard

  plugin GHI, dynamic:
    proc load(msg: string) {.order: 8.} =
      echo "THREE"
    proc update(dt: float) =
      discard

  generatePluginContext()

  when not isDynamicPluginBuild:
    loadDynamicPlugins()

    let dt = 0.0016
    let msg = "Banana"
    generatePluginFunctionCalls(update)
    generatePluginFunctionCalls(load)
    generatePluginFunctionCalls(chode)
    reloadDynamicPlugin("GHI")
    generatePluginFunctionCalls(load)
