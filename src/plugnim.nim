import std/[macros, macrocache, strformat, strutils, algorithm]

const
  PluginFunctions = CacheTable"PluginFunctions"

func pluginFunctionKey(pluginId: string, functionName: string, order: int): string =
  &"{functionName}|{pluginId}|{order}"

func pluginFunctionIdentifier(pluginId: string, functionName: string): string =
  &"{functionName}{pluginId}"

func extractFunctionNamePluginIdAndOrder(k: string): tuple[functionName, pluginId: string, order: int] =
  let splits = k.split {'|'}
  result = (splits[0], splits[1], parseInt(splits[2]))

proc extractOrder(procDef: NimNode): int =
  result = 0
  let pragmas = procDef.pragma
  if pragmas.kind != nnkPragma:
    return
  for index in 0 ..< pragmas.len:
    let p = pragmas[index]
    if p.kind == nnkExprColonExpr and p[0].eqIdent("order"):
      result = parseInt(p[1].repr)
      pragmas.del(index)
      break
  if pragmas.len == 0:
    procDef.pragma = newEmptyNode()

macro plugin*(identifier: untyped, body: untyped): auto =
  expectKind(identifier, nnkIdent)
  result = nnkStmtList.newTree()
  for stmt in body:
     expectKind(stmt, nnkProcDef)
     let functionName = stmt[0].repr
     let order = extractOrder(stmt)
     let key = pluginFunctionKey(identifier.repr, functionName, order)
     PluginFunctions[key] = stmt
     var stmt2 = stmt
     stmt2[0] = ident(pluginFunctionIdentifier(identifier.repr, functionName))
     result.add(stmt2)

macro generatePluginFunctionCalls*(functionName: untyped): auto =
  expectKind(functionName, nnkIdent)
  var calls: seq[tuple[order: int, call: NimNode]]
  for k, v in PluginFunctions:
    let (fnName, pluginId, order) = extractFunctionNamePluginIdAndOrder(k)
    if functionName.repr != fnName:
      continue
    let formalParams = v[3]
    expectKind(formalParams, nnkFormalParams)
    var call = nnkCall.newTree(ident pluginFunctionIdentifier(pluginId, fnName))
    # formalParams[0] is return type
    for index in 1 ..< formalParams.len:
      let param = formalParams[index]
      call.add(ident(param[0].repr))
    calls.add((order, call))
  result = nnkStmtList.newTree()
  for entry in calls.sortedByIt(it.order):
    result.add(entry.call)

when isMainModule:
  expandMacros:
    plugin ABC:
      proc load {.order: 10.} =
        echo "ONE"
      proc chode =
        echo "CHODE"
      proc update(dt: float) =
        discard
        
    plugin DEF:
      proc load {.order: 9.} =
        echo "TWO"
      proc update(dt: float) =
        discard
        
    plugin GHI:
      proc load(msg: string) {.order: 8.} =
        echo "THREE"
      proc update(dt: float) =
        discard

    let dt = 0.0016
    let msg = "Banana"
    generatePluginFunctionCalls(update)
    generatePluginFunctionCalls(load)
    generatePluginFunctionCalls(chode)
