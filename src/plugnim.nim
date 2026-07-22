import std/[macros, macrocache, strformat, strutils]

const
  PluginFunctions = CacheTable"PluginFunctions"

func pluginFunctionKey(pluginId: string, functionName: string): string =
  &"{functionName}|{pluginId}"

func pluginFunctionIdentifier(pluginId: string, functionName: string): string =
  &"{functionName}{pluginId}"

func extractFunctionNameAndPluginId(k: string): tuple[functionName, pluginId: string] =
  let splits = k.split {'|'}
  result = (splits[0], splits[1])

macro plugin*(identifier: untyped, body: untyped): auto =
  expectKind(identifier, nnkIdent)
  result = nnkStmtList.newTree()
  for stmt in body:
     expectKind(stmt, nnkProcDef)
     let functionName = stmt[0].repr
     let key = pluginFunctionKey(identifier.repr, functionName)
     PluginFunctions[key] = stmt
     var stmt2 = stmt
     stmt2[0] = ident(pluginFunctionIdentifier(identifier.repr, functionName))
     result.add(stmt2)

macro generatePluginFunctionCalls*(functionName: untyped): auto =
  expectKind(functionName, nnkIdent)
  var stmts = nnkStmtList.newTree()
  for k, v in PluginFunctions:
    let (fnName, pluginId) = extractFunctionNameAndPluginId(k)
    if functionName.repr != fnName:
      continue
    let formalParams = v[3]
    expectKind(formalParams, nnkFormalParams)
    var call = nnkCall.newTree(ident pluginFunctionIdentifier(pluginId, fnName))
    # formalParams[0] is return type
    for index in 1 ..< formalParams.len:
      let param = formalParams[index]
      call.add(ident(param[0].repr))
    stmts.add(call)
  result = stmts

when isMainModule:
  expandMacros:
    plugin ABC:
      proc load =
        discard
      proc chode =
        echo "CHODE"
      proc update(dt: float) =
        discard

    let dt = 0.0016
    generatePluginFunctionCalls(update)
    generatePluginFunctionCalls(load)
    generatePluginFunctionCalls(chode)
