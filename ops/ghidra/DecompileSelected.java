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
        if (unwind.length % 12 != 0) throw new IllegalArgumentException("Incomplete unwind records");
        java.nio.ByteBuffer records = java.nio.ByteBuffer.wrap(unwind).order(java.nio.ByteOrder.LITTLE_ENDIAN);
        List<String> lines = Files.readAllLines(Path.of(args[3]), StandardCharsets.UTF_8);
        if (lines.size() > 128) throw new IllegalArgumentException("Too many selected functions");
        java.util.ArrayList<Function> selected = new java.util.ArrayList<>();
        long imageBase = currentProgram.getMinAddress().getOffset() - 0x1000;
        for (String line : lines) {
            if (line.isBlank() || line.startsWith("#")) continue;
            String[] fields = line.split(",", -1);
            if (fields.length != 2 || !fields[0].matches("[a-zA-Z0-9_]+")) throw new IllegalArgumentException("Expected function_name,hex_address");
            long start = Long.parseUnsignedLong(fields[1], 16);
            long end = 0;
            for (int offset = 0; offset < unwind.length; offset += 12) {
                long begin = imageBase + Integer.toUnsignedLong(records.getInt(offset));
                long finish = imageBase + Integer.toUnsignedLong(records.getInt(offset + 4));
                if (begin == start && finish > start) { end = finish; break; }
            }
            if (end == 0 || end - start > 0x10000) throw new IllegalArgumentException("Missing or excessive function range: " + fields[0]);
            Address address = toAddr(start);
            AddressSet body = new AddressSet(address, toAddr(end - 1));
            DisassembleCommand command = new DisassembleCommand(address, body, true);
            if (!command.applyTo(currentProgram, monitor)) throw new IllegalStateException("Could not disassemble " + fields[0]);
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
