import std/[
  macros, macrocache, strformat, strutils, sequtils, algorithm, os, dynlib, osproc,
  streams, times,
]

## Everything plugnim defines and generates is GC-safe: plugin functions are
## called through the generated dispatchers, so if plugnim's own state or
## emitted code were not gcsafe, every host routine touching it would be
## flagged `not GC-safe` too.

{.push gcsafe.}

const
  StaticPlugins = CacheSeq"plugnim.static"
  DynamicPlugins = CacheSeq"plugnim.dynamic"
  WatchedDynamicPlugins = CacheSeq"plugnim.dynamic.watched"
  PluginStates = CacheSeq"plugnim.states"
  ContextGenerated = CacheSeq"plugnim.contextGenerated"
  PlugnimDir = currentSourcePath().parentDir
  NimCompiler = getCurrentCompilerExe()
  DynlibExt =
    when defined(windows):
      ".dll"
    elif defined(macosx):
      ".dylib"
    else:
      ".so"
  contextSignatureSymbol = "plugnimContextSignature"
  plugnimPluginId {.strdefine.} = ""
  pluginControlsField = "pluginControls"
  pluginWatchDebounceSeconds = 0.25
  pluginWatchScanSeconds = 0.25

const isDynamicPluginBuild* = plugnimPluginId.len > 0

type PluginControls* = object
  listPlugins*: proc(): cstring {.cdecl, gcsafe.}
  reloadPlugin*: proc(pluginId: cstring): bool {.cdecl, gcsafe.}
  requestFrame*: proc() {.cdecl, gcsafe.}
  setWidgetText*: proc(id: uint64, text: cstring) {.cdecl, gcsafe.}
  buildStatus*: proc(): cstring {.cdecl, gcsafe.}
  lastOutput*: proc(): cstring {.cdecl, gcsafe.}
  lastError*: proc(): cstring {.cdecl, gcsafe.}

var
  plugnimLastOutput* {.threadvar.}: string
  plugnimLastError* {.threadvar.}: string
  plugnimBuildStatus* {.threadvar.}: string
  plugnimRuntimeFrameRequested* {.threadvar.}: bool
  plugnimSetWidgetTextCallback*:
    proc(id: uint64, text: cstring) {.cdecl, gcsafe.}

plugnimLastOutput = ""
plugnimLastError = ""
plugnimBuildStatus = "idle"
plugnimRuntimeFrameRequested = false

proc plugins*(controls: PluginControls): seq[string] =
  if controls.listPlugins.isNil:
    return
  let text = $controls.listPlugins()
  if text.len == 0:
    @[]
  else:
    text.splitLines()

proc reload*(controls: PluginControls, pluginId: string): bool {.discardable.} =
  if controls.reloadPlugin.isNil:
    false
  else:
    controls.reloadPlugin(pluginId.cstring)

proc requestFrame*(controls: PluginControls) =
  if not controls.requestFrame.isNil:
    controls.requestFrame()

proc setWidgetTextValue*(controls: PluginControls, id: uint64, text: string) =
  if not controls.setWidgetText.isNil:
    controls.setWidgetText(id, text.cstring)

proc consumeRuntimeFrameRequest*(): bool =
  result = plugnimRuntimeFrameRequested
  plugnimRuntimeFrameRequested = false

proc lastOutput*(controls: PluginControls): string =
  if controls.lastOutput.isNil:
    ""
  else:
    $controls.lastOutput()

proc buildStatus*(controls: PluginControls): string =
  if controls.buildStatus.isNil:
    ""
  else:
    $controls.buildStatus()

proc lastError*(controls: PluginControls): string =
  if controls.lastError.isNil:
    ""
  else:
    $controls.lastError()

func symbolName(pluginId, functionName: string): string =
  functionName & pluginId
func pointerName(pluginId, functionName: string): string =
  symbolName(pluginId, functionName) & "Pointer"
func stateVarName(pluginId, name: string): string =
  name & pluginId & "State"

proc pluginCacheDir(pluginId: string): string =
  getTempDir() / "plugnim" / pluginId

proc pluginLibPath(pluginId: string, version: int): string =
  pluginCacheDir(pluginId) / ("plugin." & $version & DynlibExt)

proc dynamicPluginCompileArgs*(pluginId, sourceFile, outPath: string): seq[string] =
  @[
    "c",
    "--app:lib",
    "--hints:off",
    "--warning:UnusedImport:off",
    "--nimcache:" & outPath.changeFileExt("") & ".nimcache",
    "-d:plugnimPluginId=" & pluginId,
    "--path:" & PlugnimDir,
    "--out:" & outPath,
    sourceFile,
  ]

proc compileDynamicPlugin*(pluginId, sourceFile, outPath: string): bool =
  createDir outPath.parentDir
  var command = @[quoteShell NimCompiler]
  for arg in dynamicPluginCompileArgs(pluginId, sourceFile, outPath):
    command.add quoteShell(arg)
  echo "plugnim: compiling plugin '", pluginId, "'"
  let (output, exitCode) = execCmdEx(command.join(" "))
  plugnimLastOutput = output
  if output.len > 0:
    stdout.write output
  result = exitCode == 0
  plugnimLastError =
    if result:
      ""
    else:
      output
  if not result:
    echo "plugnim: could not compile plugin '",
      pluginId, "' (see the nim errors above)."
    echo "         source: ", sourceFile
    echo "         if this was a reload, the previously loaded version stays active."

proc startDynamicPluginCompile*(
    pluginId, sourceFile, outPath: string
): Process {.raises: [OSError, IOError].} =
  createDir outPath.parentDir
  echo "plugnim: compiling plugin '", pluginId, "'"
  startProcess(
    NimCompiler,
    args = dynamicPluginCompileArgs(pluginId, sourceFile, outPath),
    options = {poStdErrToStdOut},
  )

proc finishDynamicPluginCompile*(process: Process): tuple[output: string, exitCode: int] =
  result.exitCode = process.peekExitCode()
  result.output = process.outputStream().readAll()
  process.close()

proc dynamicPluginCompileRunning*(process: Process): bool =
  process.running

proc openPluginLib(path: string): LibHandle =
  loadLib(path)

proc closePluginLib(lib: LibHandle) =
  if not lib.isNil:
    unloadLib(lib)

proc pluginSymbol(lib: LibHandle, name: string): pointer =
  lib.symAddr(name)

proc pluginLibSignature*(lib: LibHandle): string =
  let symbol = lib.symAddr(contextSignatureSymbol)
  if symbol.isNil:
    return ""
  $cast[proc(): cstring {.cdecl, gcsafe.}](symbol)()

proc checkPluginSignature(pluginId: string, lib: LibHandle, expected: string): bool =
  let actual = pluginLibSignature(lib)
  if actual == expected:
    return true
  plugnimLastError = "plugin '" & pluginId & "' context signature mismatch: host " &
    (if expected.len == 0: "(no shared state)" else: expected) &
    ", plugin " & (if actual.len == 0: "(no shared state)" else: actual)
  echo "plugnim: refusing to activate plugin '", pluginId, "'."
  echo "  Its shared-state contract changed since the host program was built. The host"
  echo "  and plugin must agree on the context layout, otherwise the plugin would read"
  echo "  and write the wrong fields and corrupt memory. Rebuild the host to adopt the"
  echo "  new contract; the previously loaded version stays active."
  echo "  host was built for: ",
    (if expected.len == 0: "(no shared state)" else: expected)
  echo "  plugin now expects: ", (if actual.len == 0: "(no shared state)" else: actual)

proc reportMissingFunction(pluginId, functionName: string) =
  plugnimLastError =
    "plugin '" & pluginId & "' no longer provides '" & functionName & "'"
  echo "plugnim: refusing to activate plugin '", pluginId, "'."
  echo "  It no longer provides '", functionName, "', which the host program calls. A"
  echo "  reloaded plugin must keep every function the host was built against. The"
  echo "  previously loaded version stays active."

proc reportOpenFailure(pluginId, path: string) =
  plugnimLastError = "plugin '" & pluginId & "' compiled but could not open " & path
  echo "plugnim: compiled plugin '",
    pluginId, "' but could not open its library at ", path

func exported(name: string): NimNode =
  postfix(ident name, "*")
func ptrTo(name: string): NimNode =
  nnkPtrTy.newTree(ident name)
func ptrTo(typ: NimNode): NimNode =
  nnkPtrTy.newTree(copyNimTree(typ))

func contextFieldType(typ: NimNode): NimNode =
  if typ.kind == nnkVarTy:
    copyNimTree(typ[0])
  else:
    copyNimTree(typ)

func contextFieldSignature(name: string, typ: NimNode): string =
  name & ":" & contextFieldType(typ).repr

func contextPtrTo(typ: NimNode): NimNode =
  nnkPtrTy.newTree(contextFieldType(typ))

func threadVarSection(name, typ, init: NimNode): NimNode =
  ## A thread-local variable: thread vars can't carry an initializer in the
  ## declaration, so this emits the pragma-wrapped name plus a module-level
  ## `name = init` statement (the parser's var form: pragmaExpr, type, val).
  let pragmaName = nnkPragmaExpr.newTree(
    copyNimTree(name), nnkPragma.newTree(ident"threadvar"))
  let declaredType =
    if typ.kind == nnkEmpty: nnkTypeOfExpr.newTree(copyNimTree(init))
    else: copyNimTree(typ)
  result = newStmtList(nnkVarSection.newTree(
    nnkIdentDefs.newTree(pragmaName, declaredType, newEmptyNode())))
  if init.kind != nnkEmpty:
    let target =
      if name.kind == nnkPostfix: name[1]
      else: name
    result.add newAssignment(ident(target.strVal), copyNimTree(init))

template pluginParams(procDef: NimNode): seq[tuple[name: string, typ: NimNode]] =
  block:
    var res: seq[tuple[name: string, typ: NimNode]]
    let formalParams = procDef.params
    for i in 1 ..< formalParams.len:
      let defs = formalParams[i]
      for j in 0 ..< defs.len - 2:
        res.add((defs[j].strVal, defs[^2]))
    res

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

template register(cache: CacheSeq, identifier, procDef: NimNode) =
  cache.add nnkPar.newTree(
    newLit identifier.strVal,
    newLit identifier.lineInfoObj.filename,
    newLit extractOrder(procDef),
    procDef,
  )

template registerState(pluginId, name: string) =
  PluginStates.add nnkPar.newTree(newLit pluginId, newLit name)

template registerWatchedDynamicPlugin(identifier: NimNode) =
  block:
    var already = false
    var idx = 0
    while idx < WatchedDynamicPlugins.len:
      let entry = WatchedDynamicPlugins[idx]
      inc idx
      if entry[0].strVal == identifier.strVal:
        already = true
        break
    if not already:
      WatchedDynamicPlugins.add nnkPar.newTree(
        newLit identifier.strVal,
        newLit identifier.lineInfoObj.filename,
      )

template isWatchedDynamicPlugin(pluginId: string): bool =
  block:
    var found = false
    var idx = 0
    while idx < WatchedDynamicPlugins.len:
      let entry = WatchedDynamicPlugins[idx]
      inc idx
      if entry[0].strVal == pluginId:
        found = true
        break
    found

template pluginStateNames(pluginId: string): seq[string] =
  block:
    var res: seq[string]
    var idx = 0
    while idx < PluginStates.len:
      let entry = PluginStates[idx]
      inc idx
      if entry[0].strVal == pluginId:
        res.add entry[1].strVal
    res

template plugins(
    cache: CacheSeq
): seq[tuple[pluginId, functionName, file: string, order: int, def: NimNode]] =
  block:
    var res: seq[tuple[pluginId, functionName, file: string, order: int, def: NimNode]]
    var idx = 0
    while idx < cache.len:
      let entry = cache[idx]
      inc idx
      let def = entry[3]
      res.add((entry[0].strVal, def.name.strVal, entry[1].strVal, int(entry[2].intVal), def))
    res

template dynamicPluginFiles(): seq[tuple[pluginId, file: string]] =
  block:
    var res: seq[tuple[pluginId, file: string]]
    var seen: seq[string]
    for p in plugins(DynamicPlugins):
      if p.pluginId notin seen:
        seen.add p.pluginId
        res.add((p.pluginId, p.file))
    res

proc expectPluginBody(identifier, body: NimNode)
proc expectPluginProc(identifier, node: NimNode)

proc validateDynamicPlugin(identifier, body: NimNode) =
  expectPluginBody(identifier, body)
  for item in body:
    if item.kind in {nnkVarSection, nnkLetSection}:
      error "dynamic plugin '" & identifier.strVal & "' can't declare private state.\n" &
        "  Dynamic plugins share one context across the shared-library boundary, so there\n" &
        "  is nowhere to keep per-plugin state. Use a static plugin for private state.",
        item
    expectPluginProc(identifier, item)
    if item[2].kind != nnkEmpty:
      error "dynamic plugin function '" & item.name.strVal & "' can't be generic.\n" &
        "  its parameters must be concrete types so the shared context has a fixed layout.",
        item[2]
    if item.params[0].kind != nnkEmpty:
      error "dynamic plugin function '" & item.name.strVal &
        "' declares a return type.\n" &
        "  Dynamic plugins are called across a shared-library boundary through void function\n" &
        "  pointers, so they can't return a value. Communicate results through plugin state\n" &
        "  (a parameter), which becomes part of the generated context.", item.params[0]

template registerDynamicPlugin(identifier, body: NimNode) =
  for item in body:
    register(DynamicPlugins, identifier, item)

template watchedDynamicPluginEntries(): seq[tuple[pluginId, file: string]] =
  block:
    var res: seq[tuple[pluginId, file: string]]
    for (pluginId, file) in dynamicPluginFiles():
      if pluginId.isWatchedDynamicPlugin:
        res.add (pluginId, file)
    res

template knownFunctionNames(): seq[string] =
  block:
    var res: seq[string]
    for p in plugins(StaticPlugins):
      res.add p.functionName
    for p in plugins(DynamicPlugins):
      res.add p.functionName
    res.deduplicate

template contextFields(): seq[tuple[name: string, typ: NimNode, plugin: string]] =
  block:
    var res: seq[tuple[name: string, typ: NimNode, plugin: string]]
    for p in plugins(DynamicPlugins):
      for (name, typ) in pluginParams(p.def):
        if name == pluginControlsField:
          continue
        var known = false
        for existing in res:
          if existing.name == name:
            known = true
            if contextFieldType(existing.typ).repr != contextFieldType(typ).repr:
              error "dynamic plugins disagree on the type of shared state '" & name &
                "'.\n" & "  plugin '" & existing.plugin & "' declares it as " &
                existing.typ.repr & "\n" & "  plugin '" & p.pluginId & "' declares it as " &
                typ.repr & "\n" &
                "  All dynamic plugins share one context object, so each state name must have\n" &
                "  a single consistent type across every plugin.", typ
        if not known:
          res.add (name, typ, p.pluginId)
    res

proc expectPluginBody(identifier, body: NimNode) =
  if identifier.kind != nnkIdent:
    error "a plugin needs a single name, e.g. `plugin Physics:`.\n  got: " &
      identifier.repr, identifier
  if body.kind != nnkStmtList:
    error "a plugin body must be an indented block of proc definitions.", body

proc expectPluginProc(identifier, node: NimNode) =
  if node.kind != nnkProcDef:
    error "plugin '" & identifier.strVal & "' may only contain `proc` definitions.\n" &
      "  this statement isn't a proc — move it outside the plugin block.", node

macro plugin*(identifier, body: untyped): untyped =
  expectPluginBody(identifier, body)
  result = newStmtList()
  let controlsType = bindSym"PluginControls"
  result.add quote do:
    when not declared(plugnimPluginControls):
      var plugnimPluginControls {.inject.}: `controlsType`
  for item in body:
    case item.kind
    of nnkProcDef:
      register(StaticPlugins, identifier, item)
      var emitted = nnkProcDef.newTree()
      for child in item:
        emitted.add copyNimTree(child)
      emitted.name = newTree(nnkPostfix, ident"*",
        ident symbolName(identifier.strVal, item.name.strVal))
      var hasControlsParam = false
      for (name, _) in pluginParams(item):
        if name == pluginControlsField:
          hasControlsParam = true
          break
      if not hasControlsParam:
        let originalBody = emitted.body
        emitted.body = newStmtList(
          quote do:
            template pluginControls: untyped =
              plugnimPluginControls
          ,
          originalBody,
        )
      result.add emitted
    of nnkVarSection, nnkLetSection:
      for def in item:
        for i in 0 ..< def.len - 2:
          let name = def[i].strVal
          registerState(identifier.strVal, name)
          result.add threadVarSection(
            newTree(nnkPostfix, ident"*", ident stateVarName(identifier.strVal, name)),
            copyNimTree(def[^2]),
            copyNimTree(def[^1]),
          )
    else:
      error "plugin '" & identifier.strVal & "' may only contain proc definitions and\n" &
        "  state declarations (`var`/`let`). Move anything else outside the plugin block.",
        item

macro plugin*(identifier, flag, body: untyped): untyped =
  if not flag.eqIdent"dynamic":
    error "unknown plugin flag '" & flag.repr & "'.\n" &
      "  the only supported flag is `dynamic`, as in `plugin Physics, dynamic:`.", flag
  validateDynamicPlugin(identifier, body)
  result = newStmtList()
  registerDynamicPlugin(identifier, body)

  when plugnimPluginId.len > 0:
    if plugnimPluginId == identifier.strVal:
      let ctxFields = contextFields()

      var fields = nnkRecList.newTree()
      fields.add newIdentDefs(exported pluginControlsField, ident"PluginControls")
      for field in ctxFields:
        fields.add newIdentDefs(exported field.name, contextPtrTo(field.typ))

      let signature = newLit ctxFields.mapIt(contextFieldSignature(it.name, it.typ)).join(";")
      result.add nnkTypeSection.newTree(
        nnkTypeDef.newTree(
          exported"PluginContext",
          newEmptyNode(),
          nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), fields),
        ),
        nnkTypeDef.newTree(
          exported"PluginFunction",
          newEmptyNode(),
          nnkProcTy.newTree(
            nnkFormalParams.newTree(
              newEmptyNode(), newIdentDefs(ident"context", ptrTo"PluginContext")
            ),
            nnkPragma.newTree(ident"cdecl", ident"gcsafe"),
          ),
        ),
      )
      result.add nnkConstSection.newTree(
        nnkConstDef.newTree(exported"pluginContextSignature", newEmptyNode(), signature)
      )

      let getter = ident contextSignatureSymbol
      result.add quote do:
        proc `getter`(): cstring {.exportc, dynlib, cdecl, gcsafe.} =
          pluginContextSignature.cstring

      let ctx = ident"plugnimContext"
      let controlsField = ident pluginControlsField
      for item in body:
        var procBody = newStmtList()
        var hasControlsParam = false
        for (name, _) in pluginParams(item):
          if name == pluginControlsField:
            hasControlsParam = true
            break
        if hasControlsParam:
          procBody.add quote do:
            template reloadDynamicPlugin(pluginId: string) =
              discard `ctx`.`controlsField`.reload(pluginId)
        else:
          procBody.add quote do:
            template pluginControls: untyped =
              `ctx`.`controlsField`
            template reloadDynamicPlugin(pluginId: string) =
              discard pluginControls.reload(pluginId)
        for (name, _) in pluginParams(item):
          let local = ident name
          if name == pluginControlsField:
            procBody.add quote do:
              template `local`: untyped =
                `ctx`.`controlsField`
          else:
            procBody.add quote do:
              template `local`: untyped =
                `ctx`.`local`[]
        procBody.add copyNimTree(item.body)
        let sym = ident symbolName(identifier.strVal, item.name.strVal)
        result.add quote do:
          proc `sym`(`ctx`: ptr PluginContext) {.exportc, dynlib, cdecl, gcsafe.} =
            `procBody`

macro plugin*(identifier, flag, watchFlag, body: untyped): untyped =
  if not flag.eqIdent"dynamic":
    error "unknown plugin flag '" & flag.repr & "'.\n" &
      "  expected `dynamic`, as in `plugin Physics, dynamic, watch:`.", flag
  if not watchFlag.eqIdent"watch":
    error "unknown dynamic plugin flag '" & watchFlag.repr & "'.\n" &
      "  expected `watch`, as in `plugin Physics, dynamic, watch:`.", watchFlag
  validateDynamicPlugin(identifier, body)
  registerWatchedDynamicPlugin(identifier)
  result = newCall(bindSym"plugin", identifier, flag, body)

macro generatePluginContext*(): untyped =
  ContextGenerated.add newLit(true)
  let ctxFields = contextFields()

  var fields = nnkRecList.newTree()
  fields.add newIdentDefs(exported pluginControlsField, ident"PluginControls")
  for field in ctxFields:
    fields.add newIdentDefs(exported field.name, contextPtrTo(field.typ))

  let signature = newLit ctxFields.mapIt(contextFieldSignature(it.name, it.typ)).join(";")

  result = newStmtList(
    nnkTypeSection.newTree(
      nnkTypeDef.newTree(
        exported"PluginContext",
        newEmptyNode(),
        nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), fields),
      ),
      nnkTypeDef.newTree(
        exported"PluginFunction",
        newEmptyNode(),
        nnkProcTy.newTree(
          nnkFormalParams.newTree(
            newEmptyNode(), newIdentDefs(ident"context", ptrTo"PluginContext")
          ),
          nnkPragma.newTree(ident"cdecl", ident"gcsafe"),
        ),
      ),
    )
  )

  result.add nnkConstSection.newTree(
    nnkConstDef.newTree(exported"pluginContextSignature", newEmptyNode(), signature)
  )

  when plugnimPluginId.len == 0:
    if DynamicPlugins.len > 0:
      result.add quote do:
        proc plugnimNoopPluginFunction(context: ptr PluginContext) {.cdecl, gcsafe.} =
          discard

      var declaredPointers: seq[string]
      for p in plugins(DynamicPlugins):
        let fnPointerName = pointerName(p.pluginId, p.functionName)
        if fnPointerName in declaredPointers:
          continue
        declaredPointers.add fnPointerName
        let fnPointer = ident fnPointerName
        result.add quote do:
          var `fnPointer`: PluginFunction = plugnimNoopPluginFunction
  else:
    let getter = ident contextSignatureSymbol
    result.add quote do:
      proc `getter`(): cstring {.exportc, dynlib, cdecl, gcsafe.} =
        pluginContextSignature.cstring

    let ctx = ident"plugnimContext"
    let controlsField = ident pluginControlsField
    for p in plugins(DynamicPlugins):
      if p.pluginId != plugnimPluginId:
        continue
      var body = newStmtList()
      var hasControlsParam = false
      for (name, _) in pluginParams(p.def):
        if name == pluginControlsField:
          hasControlsParam = true
          break
      if hasControlsParam:
        body.add quote do:
          template reloadDynamicPlugin(pluginId: string) =
            discard `ctx`.`controlsField`.reload(pluginId)
      else:
        body.add quote do:
          template pluginControls: untyped =
            `ctx`.`controlsField`
          template reloadDynamicPlugin(pluginId: string) =
            discard pluginControls.reload(pluginId)
      for (name, _) in pluginParams(p.def):
        let local = ident name
        if name == pluginControlsField:
          body.add quote do:
            template `local`: untyped =
              `ctx`.`controlsField`
        else:
          body.add quote do:
            template `local`: untyped =
              `ctx`.`local`[]
      body.add copyNimTree(p.def.body)
      let sym = ident symbolName(p.pluginId, p.functionName)
      result.add quote do:
        proc `sym`(`ctx`: ptr PluginContext) {.exportc, dynlib, cdecl, gcsafe.} =
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
      startCompile = bindSym"startDynamicPluginCompile"
      finishCompile = bindSym"finishDynamicPluginCompile"
      compileRunning = bindSym"dynamicPluginCompileRunning"
      libPath = bindSym"pluginLibPath"
      openLib = bindSym"openPluginLib"
      closeLib = bindSym"closePluginLib"
      pluginSym = bindSym"pluginSymbol"
      checkSig = bindSym"checkPluginSignature"
      reportMissing = bindSym"reportMissingFunction"
      reportOpen = bindSym"reportOpenFailure"

    var reloadBranches: seq[NimNode]
    var startBuildBranches: seq[NimNode]
    var pollBuildCalls: seq[NimNode]
    var activeBuildChecks: seq[NimNode]
    var readyBuildChecks: seq[NimNode]
    var activateReadyCalls: seq[NimNode]
    var pluginIds: seq[string]
    for (pluginId, file) in dynamicPluginFiles():
      pluginIds.add pluginId
      let
        lib = genSym(nskVar, "lib")
        version = genSym(nskVar, "version")
        buildProcess = genSym(nskVar, "buildProcess")
        buildPath = genSym(nskVar, "buildPath")
        buildActive = genSym(nskVar, "buildActive")
        readyPath = genSym(nskVar, "readyPath")
        activatePlugin = genSym(nskProc, "activatePlugin")
        loadPlugin = genSym(nskProc, "loadPlugin")
        startPluginBuild = genSym(nskProc, "startPluginBuild")
        pollPluginBuild = genSym(nskProc, "pollPluginBuild")
        hasActiveBuild = genSym(nskProc, "hasActiveBuild")
        hasReadyBuild = genSym(nskProc, "hasReadyBuild")
        activateReadyPlugin = genSym(nskProc, "activateReadyPlugin")
        candidate = genSym(nskLet, "candidate")
        path = genSym(nskLet, "path")
        pathParam = genSym(nskParam, "path")
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
        resolves.add quote do:
          let `resolved` = `pluginSym`(`candidate`, `sym`)
          if `resolved`.isNil:
            `reportMissing`(`id`, `fnName`)
            `closeLib`(`candidate`)
            return false
        assigns.add quote do:
          `fnPointer` = cast[PluginFunction](`resolved`)

      result.add quote do:
        var `lib` {.threadvar.}: LibHandle
        var `version` {.threadvar.}: int
        var `buildProcess` {.threadvar.}: Process
        var `buildPath` {.threadvar.}: string
        var `buildActive` {.threadvar.}: bool
        var `readyPath` {.threadvar.}: string

        proc `activatePlugin`(`pathParam`: string): bool {.gcsafe.} =
          let `candidate` = `openLib`(`pathParam`)
          if `candidate`.isNil:
            `reportOpen`(`id`, `pathParam`)
            return false
          if not `checkSig`(`id`, `candidate`, pluginContextSignature):
            `closeLib`(`candidate`)
            return false
          `resolves`
          let oldLib = `lib`
          `lib` = `candidate`
          `assigns`
          `closeLib`(oldLib)
          inc `version`
          true

        proc `loadPlugin`(): bool {.gcsafe.} =
          let `path` = `libPath`(`id`, `version`)
          if not `compile`(`id`, `src`, `path`):
            return false
          `activatePlugin`(`path`)

        proc `startPluginBuild`(): bool {.gcsafe.} =
          if `buildActive`:
            return false
          `buildPath` = `libPath`(`id`, `version`)
          try:
            `buildProcess` = `startCompile`(`id`, `src`, `buildPath`)
            `buildActive` = true
            plugnimBuildStatus = "building"
            plugnimLastOutput = ""
            plugnimLastError = ""
            true
          except CatchableError as error:
            plugnimBuildStatus = "failed"
            plugnimLastError = error.msg
            false

        proc `pollPluginBuild`(): bool {.gcsafe.} =
          if not `buildActive` or `compileRunning`(`buildProcess`):
            return false
          let finished = `finishCompile`(`buildProcess`)
          `buildActive` = false
          plugnimLastOutput = finished.output
          if finished.output.len > 0:
            stdout.write finished.output
          if finished.exitCode == 0:
            `readyPath` = `buildPath`
            `buildPath` = ""
            plugnimLastError = ""
            plugnimBuildStatus = "ready"
            true
          else:
            plugnimLastError = finished.output
            plugnimBuildStatus = "failed"
            echo "plugnim: could not compile plugin '", `id`,
              "' (see the nim errors above)."
            echo "         source: ", `src`
            echo "         if this was a reload, the previously loaded version stays active."
            true

        proc `hasActiveBuild`(): bool {.gcsafe.} =
          `buildActive`

        proc `hasReadyBuild`(): bool {.gcsafe.} =
          `readyPath`.len > 0

        proc `activateReadyPlugin`(): bool {.gcsafe.} =
          if `readyPath`.len == 0:
            return false
          let path = `readyPath`
          `readyPath` = ""
          if `activatePlugin`(path):
            plugnimBuildStatus = "idle"
            true
          else:
            plugnimBuildStatus = "failed"
            false

        if not `loadPlugin`():
          quit "plugnim: could not load dynamic plugin '" & `id` & "' at startup."

      reloadBranches.add nnkOfBranch.newTree(
        id,
        quote do:
          return `loadPlugin`(),
      )
      startBuildBranches.add nnkOfBranch.newTree(
        id,
        quote do:
          return `startPluginBuild`(),
      )
      pollBuildCalls.add quote do:
        result = `pollPluginBuild`() or result
      activeBuildChecks.add quote do:
        if `hasActiveBuild`():
          return true
      readyBuildChecks.add quote do:
        if `hasReadyBuild`():
          return true
      activateReadyCalls.add quote do:
        result = `activateReadyPlugin`() or result

    if reloadBranches.len > 0:
      var dispatch = nnkCaseStmt.newTree(ident"pluginId")
      var startBuildDispatch = nnkCaseStmt.newTree(ident"pluginId")
      for branch in reloadBranches:
        dispatch.add branch
      for branch in startBuildBranches:
        startBuildDispatch.add branch
      dispatch.add nnkElse.newTree(
        quote do:
          raise newException(
            ValueError, "plugnim: no dynamic plugin named '" & pluginId & "'"
          )
      )
      startBuildDispatch.add nnkElse.newTree(
        quote do:
          raise newException(
            ValueError, "plugnim: no dynamic plugin named '" & pluginId & "'"
          )
      )
      result.add newProc(
        exported"reloadDynamicPlugin",
        [ident"bool", newIdentDefs(ident"pluginId", ident"string")],
        newStmtList(dispatch),
        pragmas = nnkPragma.newTree(ident"gcsafe"),
      )
      result.add newProc(
        ident"startDynamicPluginBuild",
        [ident"bool", newIdentDefs(ident"pluginId", ident"string")],
        newStmtList(startBuildDispatch),
        pragmas = nnkPragma.newTree(ident"gcsafe"),
      )
    else:
      result.add quote do:
        proc reloadDynamicPlugin*(pluginId: string): bool {.gcsafe.} =
          raise newException(
            ValueError, "plugnim: no dynamic plugin named '" & pluginId & "'"
          )
        proc startDynamicPluginBuild(pluginId: string): bool {.gcsafe.} =
          raise newException(
            ValueError, "plugnim: no dynamic plugin named '" & pluginId & "'"
          )

    let pluginList = newLit(pluginIds.join("\n"))
    let watchedPluginType = genSym(nskType, "PlugnimWatchedPlugin")
    var watchedPluginInitializers = nnkBracket.newTree()
    for (pluginId, file) in watchedDynamicPluginEntries():
      let id = newLit pluginId
      let sourceFile = newLit file
      watchedPluginInitializers.add quote do:
        `watchedPluginType`(
          pluginId: `id`,
          sourceFile: `sourceFile`,
          lastStamp: plugnimSourceStamp(`sourceFile`),
          pendingStamp: "",
          pendingSince: 0.0,
          lastScan: 0.0,
        )
    var pollBuildsBody = newStmtList()
    for call in pollBuildCalls:
      pollBuildsBody.add call
    var activeBuildsBody = newStmtList()
    for check in activeBuildChecks:
      activeBuildsBody.add check
    activeBuildsBody.add quote do:
      discard
    var readyBuildsBody = newStmtList()
    for check in readyBuildChecks:
      readyBuildsBody.add check
    readyBuildsBody.add quote do:
      discard
    var activateReadyBody = newStmtList()
    for call in activateReadyCalls:
      activateReadyBody.add call
    result.add quote do:
      type `watchedPluginType` = object
        pluginId: string
        sourceFile: string
        lastStamp: string
        pendingStamp: string
        pendingSince: float
        lastScan: float

      var plugnimPendingReloads {.inject, threadvar.}: seq[string]

      proc plugnimWatchRoot(path: string): string {.gcsafe.} =
        var dir = path.parentDir
        result = dir
        while dir.len > 0:
          if dir.lastPathPart == "src":
            return dir
          let parent = dir.parentDir
          if parent == dir:
            break
          dir = parent

      proc plugnimSourceStamp(path: string): string {.gcsafe.} =
        let root = plugnimWatchRoot(path)
        var entries: seq[string]
        try:
          for file in walkDirRec(root):
            if file.endsWith(".nim") or file.endsWith(".nims"):
              try:
                entries.add file & ":" & $getLastModificationTime(file)
              except OSError:
                discard
        except OSError:
          discard
        if entries.len == 0:
          try:
            entries.add path & ":" & $getLastModificationTime(path)
          except OSError:
            discard
        entries.sort()
        entries.join("\n")

      var plugnimWatchedPlugins {.threadvar.}: seq[`watchedPluginType`]
      plugnimWatchedPlugins = @`watchedPluginInitializers`

      proc queueDynamicPluginReload(pluginId: string): bool {.gcsafe.} =
        if pluginId notin plugnimPendingReloads:
          plugnimPendingReloads.add pluginId
        true

      proc pollDynamicPluginWatchers(): bool {.gcsafe.} =
        let now = epochTime()
        for watcher in plugnimWatchedPlugins.mitems:
          if now - watcher.lastScan < pluginWatchScanSeconds:
            continue
          watcher.lastScan = now
          let stamp = plugnimSourceStamp(watcher.sourceFile)
          if stamp.len == 0:
            continue
          if stamp != watcher.lastStamp and stamp != watcher.pendingStamp:
            watcher.pendingStamp = stamp
            watcher.pendingSince = now
          if watcher.pendingStamp.len > 0 and
              watcher.pendingStamp != watcher.lastStamp and
              now - watcher.pendingSince >= pluginWatchDebounceSeconds:
            watcher.lastStamp = watcher.pendingStamp
            watcher.pendingStamp = ""
            discard queueDynamicPluginReload(watcher.pluginId)
            result = true

      proc hasPendingDynamicPluginReloads(): bool {.gcsafe.} =
        plugnimPendingReloads.len > 0

      proc hasActiveDynamicPluginBuilds(): bool {.gcsafe.} =
        `activeBuildsBody`

      proc pollDynamicPluginBuilds(): bool {.gcsafe.} =
        `pollBuildsBody`

      proc hasReadyDynamicPluginReloads(): bool {.gcsafe.} =
        `readyBuildsBody`

      proc activateReadyDynamicPluginReloads(): bool {.gcsafe.} =
        `activateReadyBody`

      proc processDynamicPluginReloads(): bool {.gcsafe.} =
        if plugnimPendingReloads.len == 0:
          return
        let pending = plugnimPendingReloads
        plugnimPendingReloads.setLen 0
        for pluginId in pending:
          try:
            result = startDynamicPluginBuild(pluginId) or result
          except CatchableError as error:
            plugnimLastError = error.msg

      proc plugnimListPluginsCallback(): cstring {.cdecl, gcsafe.} =
        `pluginList`.cstring

      proc plugnimReloadPluginCallback(pluginId: cstring): bool {.cdecl, gcsafe.} =
        try:
          queueDynamicPluginReload($pluginId)
        except CatchableError as error:
          plugnimLastError = error.msg
          false

      proc plugnimBuildStatusCallback(): cstring {.cdecl, gcsafe.} =
        plugnimBuildStatus.cstring

      proc plugnimRequestFrameCallback() {.cdecl, gcsafe.} =
        plugnimRuntimeFrameRequested = true

      proc plugnimSetWidgetTextControlCallback(id: uint64,
          text: cstring) {.cdecl, gcsafe.} =
        if not plugnimSetWidgetTextCallback.isNil:
          plugnimSetWidgetTextCallback(id, text)

      proc plugnimLastOutputCallback(): cstring {.cdecl, gcsafe.} =
        plugnimLastOutput.cstring

      proc plugnimLastErrorCallback(): cstring {.cdecl, gcsafe.} =
        plugnimLastError.cstring

      when not declared(plugnimPluginControls):
        var plugnimPluginControls {.inject.}: PluginControls
      plugnimPluginControls = PluginControls(
        listPlugins: plugnimListPluginsCallback,
        reloadPlugin: plugnimReloadPluginCallback,
        requestFrame: plugnimRequestFrameCallback,
        setWidgetText: plugnimSetWidgetTextControlCallback,
        buildStatus: plugnimBuildStatusCallback,
        lastOutput: plugnimLastOutputCallback,
        lastError: plugnimLastErrorCallback,
      )

macro generatePluginFunctionCalls*(functionName: untyped): untyped =
  if functionName.kind != nnkIdent:
    error "generatePluginFunctionCalls expects a plugin function name, " &
      "e.g. generatePluginFunctionCalls(update).", functionName
  result = newStmtList()
  when plugnimPluginId.len == 0:
    let wanted = functionName.strVal
    let known = knownFunctionNames()
    if wanted notin known:
      # error "no plugin defines a function named '" & wanted & "'.\n" &
      #   "  known plugin functions: " & (if known.len == 0: "(none)" else: known.join(", ")), functionName
      return

    var calls: seq[tuple[order: int, call: NimNode]]
    var hasDynamic = false
    var usesControls = false

    for p in plugins(StaticPlugins):
      if p.functionName != wanted:
        continue
      let states = pluginStateNames(p.pluginId)
      var call = newCall(ident symbolName(p.pluginId, p.functionName))
      var used: seq[string]
      for (name, _) in pluginParams(p.def):
        if name == pluginControlsField:
          usesControls = true
          call.add ident"plugnimPluginControls"
        else:
          call.add ident(name)
        if name in states and name notin used:
          used.add name
      if used.len == 0:
        calls.add (p.order, call)
      else:
        var body = newStmtList()
        var fallbackCall = newCall(ident symbolName(p.pluginId, p.functionName))
        var copyable = newLit true
        for (name, _) in pluginParams(p.def):
          if name == pluginControlsField:
            usesControls = true
            fallbackCall.add ident"plugnimPluginControls"
          elif name in states:
            let stateVar = ident stateVarName(p.pluginId, name)
            fallbackCall.add stateVar
            copyable = infix(
              copyable,
              "and",
              newCall(ident"compiles", newCall(ident"`=copy`", stateVar, stateVar)),
            )
          else:
            fallbackCall.add ident name
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
        let copyBlock = nnkBlockStmt.newTree(newEmptyNode(), body)
        calls.add (p.order, quote do:
          when `copyable`:
            `copyBlock`
          else:
            `fallbackCall`
        )

    for p in plugins(DynamicPlugins):
      if p.functionName != wanted:
        continue
      hasDynamic = true
      let ctx = genSym(nskVar, "context")
      let checkCtx = genSym(nskVar, "checkContext")
      let controlsField = ident pluginControlsField
      var assignments = newStmtList()
      var checkAssignments = newStmtList()
      assignments.add newAssignment(
        newDotExpr(ctx, controlsField), ident"plugnimPluginControls"
      )
      for (name, _) in pluginParams(p.def):
        if name == pluginControlsField:
          continue
        let local = ident name
        assignments.add newAssignment(
          newDotExpr(ctx, local), newCall(ident"unsafeAddr", local)
        )
        checkAssignments.add newAssignment(
          newDotExpr(checkCtx, local), newCall(ident"unsafeAddr", local)
        )
      let fnPointer = ident pointerName(p.pluginId, p.functionName)
      let call = newCall(fnPointer, newCall(ident"addr", ctx))
      calls.add (p.order, quote do:
        when compiles(block:
          var `checkCtx`: PluginContext
          `checkAssignments`
        ):
          block:
            var `ctx`: PluginContext
            `assignments`
            `call`
      )

    if hasDynamic and ContextGenerated.len == 0:
      error "generatePluginFunctionCalls(" & wanted & ") needs the plugin context, but\n" &
        "  generatePluginContext() has not been called yet. Call it once after your plugin\n" &
        "  blocks and before generating any calls."

    for entry in calls.sortedByIt(it.order):
      result.add entry.call

when isMainModule:
  expandMacros:
    plugin ABC:
      var banana = 42
      proc load() {.order: 10.} =
        echo "ONE"
    
      proc chode(banana: int) =
        echo &"CHODE {banana}"
    
      proc update(dt: float) =
        discard

  plugin DEF:
    proc load() {.order: 9.} =
      echo "TWO"

    proc update(dt: float) =
      discard

  plugin GHI:
    proc load(msg: string) {.order: 8.} =
      echo "THREE"

    proc update(dt: float) =
      echo "123"

  generatePluginContext()

  when not isDynamicPluginBuild:
    loadDynamicPlugins()

    let dt = 0.0016
    let msg = "Banana"
    var banana: int = 0

    expandMacros:
      generatePluginFunctionCalls(update)
