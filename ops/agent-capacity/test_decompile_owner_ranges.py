"""Compile the exact pure Java range resolver without loading or running Ghidra."""
import argparse
import subprocess
import uuid
from pathlib import Path

HARNESS = r'''
public class OwnerRangesTest {
RESOLVER
    static byte[] pdata(long[][] rows) {
        var bytes = java.nio.ByteBuffer.allocate(rows.length * 12).order(java.nio.ByteOrder.LITTLE_ENDIAN);
        for (long[] row : rows) for (long value : row) bytes.putInt((int)value);
        return bytes.array();
    }
    static byte[] chainData(long[][] rows) {
        byte[] data = new byte[rows.length * 32];
        data[0] = 1;
        var bytes = java.nio.ByteBuffer.wrap(data).order(java.nio.ByteOrder.LITTLE_ENDIAN);
        for (int i = 1; i < rows.length; ++i) {
            data[i * 32] = 0x21;
            for (int field = 0; field < 3; ++field) bytes.putInt(i * 32 + 4 + field * 4, (int)rows[i-1][field]);
        }
        return data;
    }
    static void reject(Runnable action) {
        try { action.run(); } catch (IllegalArgumentException expected) { return; }
        throw new AssertionError("Invalid owner accepted");
    }
    public static void main(String[] args) throws Exception {
        long[][] rows = {{0x1000,0x1010,0x10000},{0x1010,0x1020,0x10020},{0x1030,0x1040,0x10040}};
        byte[] data = chainData(rows);
        // Odd CountOfCodes requires a padded slot before the chain record.
        data[34] = 1;
        var bytes = java.nio.ByteBuffer.wrap(data).order(java.nio.ByteOrder.LITTLE_ENDIAN);
        for (int i=0;i<3;++i) bytes.putInt(40+i*4,(int)rows[0][i]);
        var owners = new OwnerRanges(pdata(rows), data, 0x100000, 0x110000);
        var spans = owners.spans(0x101000);
        if (spans.size()!=2 || spans.get(0)[0]!=0x101000 || spans.get(0)[1]!=0x101020 || spans.get(1)[0]!=0x101030 || spans.get(1)[1]!=0x101040)
            throw new AssertionError("Union or chain padding incorrect");
        reject(() -> owners.spans(0x101010));
        byte[] cycle=chainData(rows);
        var c=java.nio.ByteBuffer.wrap(cycle).order(java.nio.ByteOrder.LITTLE_ENDIAN);
        for(int i=0;i<3;++i)c.putInt(36+i*4,(int)rows[2][i]);
        reject(() -> new OwnerRanges(pdata(rows),cycle,0x100000,0x110000).spans(0x101000));
        reject(() -> new OwnerRanges(pdata(new long[][]{rows[1],rows[2]}),data,0x100000,0x110000).spans(0x101010));
        reject(() -> new OwnerRanges(pdata(rows),new byte[1],0x100000,0x110000).spans(0x101000));
        byte[] bad=data.clone(); bad[0]=7;
        reject(() -> new OwnerRanges(pdata(rows),bad,0x100000,0x110000).spans(0x101000));
        byte[] badFlags=data.clone(); badFlags[0]=0x41;
        reject(() -> new OwnerRanges(pdata(rows),badFlags,0x100000,0x110000).spans(0x101000));
        long[][] deep=new long[34][3];
        for(int i=0;i<deep.length;++i)deep[i]=new long[]{0x1000+i*16,0x1010+i*16,0x10000+i*32};
        reject(() -> new OwnerRanges(pdata(deep),chainData(deep),0x100000,0x110000).spans(0x101000));
        reject(() -> new OwnerRanges(pdata(new long[][]{{0x1000,0x11001,0x10000}}),new byte[]{1,0,0,0},0x100000,0x110000).spans(0x101000));
        System.out.println("PASS: exact Java resolver union, padding, fragment, cycle, missing parent, truncation, version, depth, size");
        if(args.length==2){
            var captured=new OwnerRanges(java.nio.file.Files.readAllBytes(java.nio.file.Path.of(args[0])),java.nio.file.Files.readAllBytes(java.nio.file.Path.of(args[1])),0x140000000L,0x141435000L);
            long[][] expected={{0x140449450L,0x1404494D7L},{0x1401823C0L,0x140183488L},{0x140C1A190L,0x140C1A21EL},{0x1405B00B0L,0x1405B0108L}};
            for(long[] range:expected){var actual=captured.spans(range[0]);if(actual.size()!=1 || actual.get(0)[0]!=range[0] || actual.get(0)[1]!=range[1])throw new AssertionError("Captured chain union differs");}
            System.out.println("PASS: four retained metadata owners complete; no text scan or Ghidra");
        }
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--java', type=Path, required=True)
    parser.add_argument('--reference-root', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    source = (root / 'ops/ghidra/DecompileSelected.java').read_text(encoding='utf-8')
    pure = source.split('// BEGIN PURE OWNER RANGES')[1].split('\n', 1)[1].split('// END PURE OWNER RANGES')[0]
    destination = root / 'runtime/agent-capacity' / ('owner-tests-' + uuid.uuid4().hex)
    destination.mkdir(parents=True)
    test = destination / 'OwnerRangesTest.java'
    test.write_text(HARNESS.replace('RESOLVER', pure), encoding='utf-8')
    command = [str(args.java), '-Xmx512m', '--source', '21', str(test)]
    if args.reference_root:
        command.extend(str(args.reference_root / name) for name in ('unpacked-pdata.bin', 'unpacked-rdata.bin'))
    subprocess.run(command, check=True, timeout=30)


if __name__ == '__main__':
    main()
