// Decompile selected functions from a local raw code section. Output stays local.
// @category Analysis
import ghidra.app.script.GhidraScript;
import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.decompiler.DecompInterface;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSet;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.SourceType;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

public class DecompileSelected extends GhidraScript {
    // BEGIN PURE OWNER RANGES -- exercised without loading Ghidra.
    static final class OwnerRanges {
        private record RF(long begin, long end, long unwind) { }
        private final java.util.Set<RF> records = new java.util.HashSet<>();
        private final java.util.Map<RF, RF> roots = new java.util.HashMap<>();
        private final java.util.Map<RF, Integer> depths = new java.util.HashMap<>();
        private final byte[] data;
        private final long imageBase;
        private final long dataBase;

        OwnerRanges(byte[] pdata, byte[] data, long imageBase, long dataBase) {
            if (pdata.length % 12 != 0) throw new IllegalArgumentException("Incomplete unwind records");
            this.data = data;
            this.imageBase = imageBase;
            this.dataBase = dataBase;
            java.nio.ByteBuffer input = java.nio.ByteBuffer.wrap(pdata).order(java.nio.ByteOrder.LITTLE_ENDIAN);
            for (int offset = 0; offset < pdata.length; offset += 12) {
                RF record = readRF(input, offset);
                if (record.begin >= record.end) throw new IllegalArgumentException("Invalid pdata span");
                records.add(record);
            }
        }

        private static RF readRF(java.nio.ByteBuffer input, int offset) {
            return new RF(Integer.toUnsignedLong(input.getInt(offset)),
                          Integer.toUnsignedLong(input.getInt(offset + 4)),
                          Integer.toUnsignedLong(input.getInt(offset + 8)));
        }

        private RF root(RF record, java.util.Set<RF> ancestors) {
            RF cached = roots.get(record);
            if (cached != null) {
                if (ancestors.size() + depths.get(record) > 32)
                    throw new IllegalArgumentException("Unwind depth");
                return cached;
            }
            if (ancestors.size() >= 32 || !ancestors.add(record))
                throw new IllegalArgumentException("Unwind cycle/depth");
            long relative = imageBase + record.unwind - dataBase;
            if (relative < 0 || relative > data.length - 4)
                throw new IllegalArgumentException("Unwind outside captured data");
            int offset = (int)relative;
            int header = Byte.toUnsignedInt(data[offset]);
            if ((header & 7) != 1 && (header & 7) != 2)
                throw new IllegalArgumentException("Unsupported unwind version");
            int flags = header >>> 3;
            if ((flags & ~7) != 0) throw new IllegalArgumentException("Unknown unwind flags");
            int count = Byte.toUnsignedInt(data[offset + 2]);
            int tail = offset + 4 + ((count + 1) & ~1) * 2;
            if (tail > data.length) throw new IllegalArgumentException("Truncated unwind codes");
            if ((flags & 3) != 0 && tail > data.length - 4)
                throw new IllegalArgumentException("Truncated unwind handler");
            RF result = record;
            int depth = 1;
            if ((flags & 4) != 0) {
                if ((flags & 3) != 0 || tail > data.length - 12)
                    throw new IllegalArgumentException("Invalid/truncated unwind chain");
                RF parent = readRF(java.nio.ByteBuffer.wrap(data).order(java.nio.ByteOrder.LITTLE_ENDIAN), tail);
                if (!records.contains(parent)) throw new IllegalArgumentException("Missing chain parent");
                result = root(parent, ancestors);
                depth += depths.get(parent);
            }
            ancestors.remove(record);
            roots.put(record, result);
            depths.put(record, depth);
            return result;
        }

        java.util.List<long[]> spans(long selectedStart) {
            RF selected = null;
            for (RF record : records) {
                if (imageBase + record.begin == selectedStart) {
                    if (selected != null) throw new IllegalArgumentException("Ambiguous selected start");
                    selected = record;
                }
            }
            if (selected == null) throw new IllegalArgumentException("Missing selected pdata record");
            RF selectedRoot = root(selected, new java.util.HashSet<>());
            if (!selected.equals(selectedRoot)) throw new IllegalArgumentException("Select logical root, not chain fragment");
            java.util.ArrayList<long[]> fragments = new java.util.ArrayList<>();
            // Every table record is resolved: an incomplete child must never silently disappear.
            for (RF record : records) {
                if (root(record, new java.util.HashSet<>()).equals(selectedRoot))
                    fragments.add(new long[]{imageBase + record.begin, imageBase + record.end});
            }
            fragments.sort(java.util.Comparator.comparingLong(span -> span[0]));
            java.util.ArrayList<long[]> merged = new java.util.ArrayList<>();
            for (long[] span : fragments) {
                if (!merged.isEmpty() && span[0] <= merged.get(merged.size() - 1)[1]) {
                    long[] previous = merged.get(merged.size() - 1);
                    previous[1] = Math.max(previous[1], span[1]);
                } else merged.add(span.clone());
            }
            long size = 0;
            for (long[] span : merged) size += span[1] - span[0];
            if (size == 0 || size > 0x10000) throw new IllegalArgumentException("Excessive owner union");
            return merged;
        }
    }
    // END PURE OWNER RANGES

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 5) throw new IllegalArgumentException("Expected: data-section data-base unwind-table function-list output-file");
        Path dataPath = Path.of(args[0]);
        long dataBase = Long.parseUnsignedLong(args[1], 16);
        try (InputStream input = Files.newInputStream(dataPath)) {
            currentProgram.getMemory().createInitializedBlock("readonly_data", toAddr(dataBase), input, Files.size(dataPath), monitor, false);
        }
        byte[] unwind = Files.readAllBytes(Path.of(args[2]));
        List<String> lines = Files.readAllLines(Path.of(args[3]), StandardCharsets.UTF_8);
        if (lines.size() > 128) throw new IllegalArgumentException("Too many selected functions");
        java.util.ArrayList<Function> selected = new java.util.ArrayList<>();
        long imageBase = currentProgram.getMinAddress().getOffset() - 0x1000;
        OwnerRanges owners = new OwnerRanges(unwind, Files.readAllBytes(dataPath), imageBase, dataBase);
        for (String line : lines) {
            if (line.isBlank() || line.startsWith("#")) continue;
            String[] fields = line.split(",", -1);
            if (fields.length != 2 || !fields[0].matches("[a-zA-Z0-9_]+")) throw new IllegalArgumentException("Expected function_name,hex_address");
            long start = Long.parseUnsignedLong(fields[1], 16);
            Address address = toAddr(start);
            java.util.List<long[]> spans = owners.spans(start);
            AddressSet body = new AddressSet();
            for (long[] span : spans) {
                Address first = toAddr(span[0]);
                Address last = toAddr(span[1] - 1);
                if (!currentProgram.getMemory().contains(first) || !currentProgram.getMemory().contains(last))
                    throw new IllegalArgumentException("Owner span outside imported memory");
                body.addRange(first, last);
                println(fields[0] + " owner span " + first + ".." + last);
            }
            for (long[] span : spans) {
                DisassembleCommand command = new DisassembleCommand(toAddr(span[0]), body, true);
                if (!command.applyTo(currentProgram, monitor)) throw new IllegalStateException("Could not disassemble " + fields[0]);
            }
            Function function = currentProgram.getFunctionManager().createFunction(fields[0], address, body, SourceType.USER_DEFINED);
            selected.add(function);
        }
        DecompInterface decompiler = new DecompInterface();
        StringBuilder output = new StringBuilder();
        try {
            if (!decompiler.openProgram(currentProgram)) throw new IllegalStateException("Decompiler open failed");
            for (Function function : selected) {
                monitor.checkCancelled();
                println("Decompiling " + function.getName());
                var result = decompiler.decompileFunction(function, 30, monitor);
                if (!result.decompileCompleted() || result.getDecompiledFunction() == null) throw new IllegalStateException(function.getName() + ": " + result.getErrorMessage());
                output.append("\n/* ").append(function.getName()).append(" */\n").append(result.getDecompiledFunction().getC());
            }
        } finally { decompiler.dispose(); }
        Files.writeString(Path.of(args[4]), output.toString(), StandardCharsets.UTF_8);
        println("Selected local decompilation complete. Do not commit or redistribute the output.");
    }
}
