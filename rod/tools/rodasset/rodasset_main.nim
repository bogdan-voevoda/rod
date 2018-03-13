import os, strutils, times, osproc, sets, logging, macros, tables
import imgtool, asset_cache, migrator
import settings except hash
import json except hash
import tempfile
import nimx.pathutils

const rodPluginFile {.strdefine.} = ""
when rodPluginFile.len != 0:
    macro doImport(): untyped =
        newNimNode(nnkImportStmt).add(newLit(rodPluginFile))
    doImport()

template updateSettingsWithCmdLine() =
    s.graphics.downsampleRatio *= downsampleRatio
    s.graphics.compressToPVR = compressToPVR
    if platform in ["js", "emscripten", "wasm"]:
        s.audio.extension = "mp3"
    else:
        s.audio.extension = "ogg"

proc hash(platform: string = "", downsampleRatio: float = 1.0,
        compressToPVR: bool = false, path: string) =
    let s = parseConfig(path / "config.rab")
    updateSettingsWithCmdLine()
    echo dirHash(path, s)

var gAudioConvTool = ""

proc audioConvTool(): string =
    if gAudioConvTool.len == 0:
        gAudioConvTool = findExe("ffmpeg")
        if gAudioConvTool.len == 0:
            gAudioConvTool = findExe("avconv")
    result = gAudioConvTool

let compressAudio = false

proc convertAudio(fromFile, toFile: string, mp3: bool) =
    var args = @["-i", fromFile, "-y", "-loglevel", "warning"]
    if mp3:
        args.add(["-acodec", "libmp3lame", "-write_xing", "0"])
    else: # ogg
        args.add(["-acodec", "libvorbis"])

    if compressAudio:
        let numChannels = 1
        let sampleRate = 11025
        args.add(["-ac", $numChannels, "-ar", $sampleRate])

    args.add(toFile)
    echo audioConvTool().execProcess(args, options={poStdErrToStdOut})

proc copyRemainingAssets(tool: ImgTool, src, dst, audioFmt: string, copiedFiles: var seq[string]) =
    let isMp3 = audioFmt == "mp3"
    for r in walkDirRec(src):
        let sf = r.splitFile()
        if not sf.name.startsWith('.'):
            var reldst = substr(r, src.len + 1)
            let d = dst / reldst
            var doCopy = false
            var doIndex = false
            case sf.ext
            of ".png":
                if unixToNativePath(r) notin tool.processedImages:
                    doCopy = true
            of ".wav", ".mp3", ".ogg":
                createDir(d.parentDir())
                let dest = d.changeFileExt(audioFmt)
                reldst = reldst.changeFileExt(audioFmt)
                doIndex = true
                echo "Converting/compressing audio ", r
                if isMp3:
                    convertAudio(r, dest, true)
                else:
                    convertAudio(r, dest, false)
            of ".json", ".jcomp":
                doIndex = not tool.packCompositions
            of ".rab":
                discard
            else:
                doCopy = true

            if doCopy or doIndex:
                copiedFiles.add(reldst.replace('\\', '/'))

                if doCopy:
                    echo "Copying asset: ", r
                    createDir(d.parentDir())
                    copyFile(r, d)

proc packSingleAssetBundle(s: Settings, cache: string, onlyCache: bool, src, dst: string) =
    let h = dirHash(src, s)
    createDir(cache)
    let c = cache / h
    info "cache: ", c, " for asset bundle: ", src
    if not dirExists(c):
        let tmpCacheDir = mkdtemp(h, "_tmp")
        var tool = newImgTool()

        for f in walkDirRec(src):
            if f.endsWith(".json") or f.endsWith(".jcomp"):
                var tp = f
                normalizePath(tp, false)
                tool.compositionPaths.add(tp)

        tool.noquant = s.graphics.quantizeExceptions
        tool.noposterize = s.graphics.posterizeExceptions
        tool.originalResPath = src
        tool.resPath = tmpCacheDir
        tool.outPrefix = "p"
        tool.compressOutput = s.graphics.compressOutput
        tool.compressToPVR = s.graphics.compressToPVR
        tool.downsampleRatio = s.graphics.downsampleRatio
        tool.extrusion = s.graphics.extrusion
        tool.disablePotAdjustment = s.graphics.disablePotAdjustment
        tool.packUnreferredImages = true
        tool.packCompositions = s.graphics.packCompositions
        let startTime = epochTime()
        tool.run()
        echo "Done. Time: ", epochTime() - startTime

        var copiedFiles = newSeq[string]()
        copyRemainingAssets(tool, src, tmpCacheDir, s.audio.extension, copiedFiles)

        let index = %{
            "packedImages": tool.index,
            "files": %copiedFiles,
        }
        writeFile(tmpCacheDir / "index.rodpack", index.pretty().replace(" \n", "\n"))

        when declared(moveDir):
            moveDir(tmpCacheDir, c) # Newer nim should support it
        else:
            moveFile(tmpCacheDir, c)

    if not onlyCache:
        copyResourcesFromCache(c, h, dst)

iterator assetBundles(resDir: string, fastParse: bool = false): tuple[path: string, ab: Settings] =
    let prefixLen = resDir.len + 1
    for path in walkDirRec(resDir):
        if path.endsWith("config.rab"):
            yield (path.parentDir()[prefixLen .. ^1], parseConfig(path, fastParse))

proc pack(cache: string = "", platform: string = "",
        downsampleRatio: float = 1.0, compressToPVR: bool = false,
        onlyCache: bool = false,
        debug: bool = false,
        src, dst: string) =
    #addHandler(newConsoleLogger()) # Disable logger for now, because nimx provides its own. This will likely be changed.
    let src = expandTilde(src)
    let dst = expandTilde(dst)
    let cache = getCache(cache)
    let rabFile = src / "config.rab"
    if fileExists(rabFile):
        let s = parseConfig(rabFile)
        updateSettingsWithCmdLine()
        packSingleAssetBundle(s, cache, onlyCache, src, dst)
    else:
        for path, s in assetBundles(src):
            if debug or not s.debugOnly:
                updateSettingsWithCmdLine()
                packSingleAssetBundle(s, cache, onlyCache, src & "/" & path, dst & "/" & path)


    var oldImageMapJson: JsonNode
    var oldJcompMapJson: JsonNode

    var oldImgMap = initTable[string, Table[string, int]]()
    var oldJcompMap = initTable[string, CompTree]()

    try:
        oldImageMapJson = json.parseFile("image_map.json")

        for ch in oldImageMapJson:
            var v = ch{"path"}
            if not v.isNil:
                oldImgMap[v.str] = initTable[string, int]()
            v = ch{"compositions"}
            if not v.isNil:
                for cmp in v:
                    let path = cmp{"path"}
                    let usg = cmp{"usage"}
                    if not path.isNil:
                        if not usg.isNil:
                            oldImgMap[v.str][path.str] = usg.getNum().int

        oldJcompMapJson = json.parseFile("jcomp_map.json")

        for ch in oldJcompMapJson:
            let cmp = ch.newCompTreeFromJson()
            oldJcompMap[cmp.path] = cmp
    except:
        discard


    var imageMapArr = newJArray()
    for k, j in imgMap:
        var jComps = newJArray()
        for i, s in j:
            jComps.add( json.`%*`({"path": i, "usage": $s}) )
        imageMapArr.add( json.`%*`({"path": k, "compositions": jComps}) )

    # writeFile("image_map.json", imageMapArr.pretty())

    var jMapArr = newJArray()
    # for k, j in jcompMap:
    #     jMapArr.add(j.toJson())


    # for k, j in oldJcompMap:
    #     jMapArr.add(j.toJson())

    for k, j in jcompMap:
        # if not jcompMap.hasKey(k) or jcompMap[k] != j:
        jMapArr.add(jcompMap[k].toJson())

    # writeFile("jcomp_map.json", jMapArr.pretty())


    proc cleanImgsRec(c: CompTree, res: var Table[string, int]) =
        let v = res.getOrDefault(c.path)
        res[c.path] = v + 1
        for i in c.images:
            let newImgCount = imgMap[i][c.path] - 1
            imgMap[i][c.path] = newImgCount
        for ch in c.children:
            ch.cleanImgsRec(res)

    proc removeJbranch(name: string): Table[string, int] =
        var res = initTable[string, int]()
        for k, j in jcompMap:
            let jComp = j.findComp(name)
            if not jComp.isNil:
                jComp.cleanImgsRec(res)
        result = res

    proc readyForDeleteImages(): seq[string] =
        result = @[]
        for imgPath, comps in imgMap:
            var counter = 0
            for jcompPath, count in comps:
                if count <= 0:
                    inc counter
            if counter == comps.len:
                result.add(imgPath)

    for r in walkDirRec("res"):
        let sf = r.splitFile()
        if not sf.name.startsWith('.') and not r.contains("tiledmap") and not r.contains("ios"):
            case sf.ext
            of ".png":
                if not (r in imgMap):
                    imgMap[r] = initTable[string, int]()


    # let jcompsRemove = removeJbranch("res/common/gui/popups/precomps/Tournament_Bar/Main.jcomp")
    let toDelIMg = readyForDeleteImages()
    var imgToDeleteArr = newJArray()
    for el in toDelIMg:
        imgToDeleteArr.add(%el)
    # writeFile("img_to_delete.json", imgToDeleteArr.pretty())

proc ls(debug: bool = false, androidExternal: bool = false, resDir: string) =
    for path, ab in assetBundles(resDir, true):
        var shouldList = false
        if androidExternal:
            if ab.androidExternal:
                shouldList = true
        elif debug or not ab.debugOnly:
            shouldList = true

        if shouldList: echo path

proc jsonmap(platform: string = "", downsampleRatio: float = 1.0,
        compressToPVR: bool = false, resDir: string, output: string) =
    var j = newJObject()
    for path, s in assetBundles(resDir, true):
        updateSettingsWithCmdLine()
        j[path] = %dirHash(resDir / path, s)
    createDir(output.parentDir())
    writeFile(output, $j)

when isMainModule:
    import cligen
    dispatchMulti([hash], [pack], [upgradeAssetBundle], [ls], [jsonmap])
