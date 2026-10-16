using System;
using IW7.Diagnostics.Source;

namespace IW7.Tests.Source
{
    public static class ImmutableSnapshotCursorTests
    {
        private static int assertions;
        private static void Check(bool condition, string message)
        {
            assertions++;
            if (!condition) throw new InvalidOperationException(message);
        }

        private static void Expect(CursorOutcome result, CursorAdmission admission, int? hResult,
                                   uint count, ulong before, ulong after, string message)
        {
            Check(result.Admission == admission && result.HResult == hResult &&
                  result.Count == count && result.Before == before && result.After == after, message);
        }

        private static void Throws<T>(Action action, string message) where T : Exception
        {
            bool caught = false;
            try { action(); } catch (T) { caught = true; }
            Check(caught, message);
        }

        private static SnapshotLimits Limits(int read = 16, ulong total = 128, int calls = 64, int clones = 8)
        {
            return new SnapshotLimits(16, read, total, calls, clones);
        }

        // Fake late/lazy consumer. This owns a model cursor, never a real file or provider reference.
        private sealed class LateReader : IDisposable
        {
            private readonly SnapshotCursor held;
            internal LateReader(SnapshotCursor cursor)
            {
                held = cursor.Clone().CreatedCursor;
                if (held == null) throw new InvalidOperationException("Fake owner could not retain clone.");
            }
            internal CursorOutcome ReadLater(uint count) { return held.Read(count); }
            public void Dispose() { held.Dispose(); }
        }

        private static void ImmutableBytesAndEof()
        {
            byte[] input = { 10, 20, 30 };
            using (var cursor = SnapshotCursor.CopyOf(input, Limits()))
            {
                input[0] = 99;
                Expect(cursor.Read(0), CursorAdmission.Admitted, 0, 0, 0, 0, "Zero read at start.");
                var first = cursor.Read(2);
                Expect(first, CursorAdmission.Admitted, 0, 2, 0, 2, "Complete request.");
                Check(first.GetByte(0) == 10 && first.GetByte(1) == 20, "Input alias escaped into snapshot.");
                var shortRead = cursor.Read(2);
                Expect(shortRead, CursorAdmission.Admitted, 1, 1, 2, 3, "Short EOF and actual count.");
                Check(shortRead.GetByte(0) == 30, "Short read contains invented bytes.");
                Expect(cursor.Read(0), CursorAdmission.Admitted, 0, 0, 3, 3, "Zero read at EOF.");
                Expect(cursor.Read(1), CursorAdmission.Admitted, 1, 0, 3, 3, "Positive read at EOF.");
                cursor.Seek(0, CursorOrigin.Set);
                var again = cursor.Read(1);
                Check(first.GetByte(0) == 10 && again.GetByte(0) == 10,
                      "Later reads or input mutation changed retained result/snapshot.");
                Throws<IndexOutOfRangeException>(() => shortRead.GetByte(1), "Result exposes absent bytes.");
            }
            using (var empty = SnapshotCursor.CopyOf(Array.Empty<byte>(), Limits()))
            {
                Expect(empty.Read(0), CursorAdmission.Admitted, 0, 0, 0, 0, "Empty zero read.");
                Expect(empty.Read(1), CursorAdmission.Admitted, 1, 0, 0, 0, "Empty EOF.");
                Check(empty.Observe().PayloadAllocations == 0, "Empty reads allocated payload.");
            }
        }

        private static void SeekBoundaries()
        {
            using (var cursor = SnapshotCursor.CopyOf(new byte[] { 1, 2, 3, 4 }, Limits(calls: 100)))
            {
                Expect(cursor.Seek(1, CursorOrigin.Set), CursorAdmission.Admitted, 0, 0, 0, 1, "SET.");
                Expect(cursor.Seek(2, CursorOrigin.Current), CursorAdmission.Admitted, 0, 0, 1, 3, "CUR positive.");
                Expect(cursor.Seek(-1, CursorOrigin.End), CursorAdmission.Admitted, 0, 0, 3, 3, "END negative.");
                Expect(cursor.Seek(-3, CursorOrigin.Current), CursorAdmission.Admitted, 0, 0, 3, 0, "CUR to zero.");
                Expect(cursor.Seek(-1, CursorOrigin.Current), CursorAdmission.Admitted,
                       SnapshotCursor.STG_E_INVALIDFUNCTION, 0, 0, 0, "Negative CUR must leave cursor unchanged.");
                Expect(cursor.Seek(-5, CursorOrigin.End), CursorAdmission.Admitted,
                       SnapshotCursor.STG_E_INVALIDFUNCTION, 0, 0, 0, "Negative END must fail.");
                Expect(cursor.Seek(8, (CursorOrigin)999), CursorAdmission.Admitted,
                       SnapshotCursor.STG_E_INVALIDFUNCTION, 0, 0, 0, "Invalid origin must fail.");
                Expect(cursor.Seek(long.MinValue, CursorOrigin.Set), CursorAdmission.Admitted, 0, 0, 0,
                       0x8000000000000000UL, "SET preserves unsigned high bit.");
                Expect(cursor.Seek(long.MinValue, CursorOrigin.Current), CursorAdmission.Admitted,
                       0, 0, 0x8000000000000000UL, 0, "CUR handles long.MinValue without signed negation overflow.");
                Expect(cursor.Seek(-1, CursorOrigin.Set), CursorAdmission.Admitted, 0, 0, 0,
                       ulong.MaxValue, "SET permits full unsigned range.");
                Expect(cursor.Seek(1, CursorOrigin.Current), CursorAdmission.Admitted,
                       SnapshotCursor.STG_E_INVALIDFUNCTION, 0, ulong.MaxValue, ulong.MaxValue,
                       "CUR overflow must leave cursor unchanged.");
                var before = cursor.Observe();
                Expect(cursor.Read(0), CursorAdmission.Admitted, 0, 0, ulong.MaxValue, ulong.MaxValue,
                       "Zero read beyond EOF.");
                Expect(cursor.Read(1), CursorAdmission.Admitted, 1, 0, ulong.MaxValue, ulong.MaxValue,
                       "Positive read beyond EOF.");
                var after = cursor.Observe();
                Check(after.BytesRead == before.BytesRead && after.PayloadAllocations == before.PayloadAllocations,
                      "Beyond EOF read allocated payload or accessed bytes.");
                Expect(cursor.Seek(2, CursorOrigin.End), CursorAdmission.Admitted, 0, 0, ulong.MaxValue, 6,
                       "END permits logical position beyond EOF.");
                Check(cursor.Length == 4, "Seek resized the immutable snapshot.");
                Expect(cursor.Seek(long.MinValue, CursorOrigin.End), CursorAdmission.Admitted,
                       SnapshotCursor.STG_E_INVALIDFUNCTION, 0, 6, 6, "END handles long.MinValue as invalid negative result.");
            }
        }

        private static void CloneAndRetention()
        {
            var root = SnapshotCursor.CopyOf(new byte[] { 4, 5, 6 }, Limits());
            root.Seek(1, CursorOrigin.Set);
            var cloneResult = root.Clone();
            Expect(cloneResult, CursorAdmission.Admitted, 0, 0, 1, 1, "Clone leaves original cursor unchanged.");
            var clone = cloneResult.CreatedCursor;
            Check(clone != null && clone.Position == 1 && clone.Length == 3, "Clone initial position/length.");
            clone.Read(1);
            Check(root.Position == 1 && clone.Position == 2, "Clone read moved original cursor.");
            root.Seek(0, CursorOrigin.Set);
            Check(clone.Position == 2, "Original seek moved clone cursor.");
            var late = new LateReader(clone);
            root.Dispose();
            clone.Dispose();
            var retained = root.Observe();
            Check(retained.LiveCursors == 1 && retained.LastOwnerReleases == 0, "Fake late alias lost owner too early.");
            var result = late.ReadLater(1);
            Expect(result, CursorAdmission.Admitted, 0, 1, 2, 3, "Late alias reads after original/first clone close.");
            Check(result.GetByte(0) == 6, "Late alias lost immutable bytes.");
            root.Dispose();
            late.Dispose();
            late.Dispose();
            var released = root.Observe();
            Check(released.LiveCursors == 0 && released.LastOwnerReleases == 1, "Managed last owner released more/less than once.");
            Expect(root.Read(1), CursorAdmission.Closed, null, 0, 0, 0, "Closed read is not EOF.");
            Expect(root.Seek(0, CursorOrigin.Set), CursorAdmission.Closed, null, 0, 0, 0, "Closed seek.");
            Check(root.Clone().CreatedCursor == null, "Closed cursor resurrected owner.");
            Expect(late.ReadLater(0), CursorAdmission.Closed, null, 0, 3, 3, "Closed zero read is outside admission.");
            Check(result.GetByte(0) == 6, "Closing model owner changed detached read result.");
        }

        private static void SharedLimits()
        {
            using (var cursor = SnapshotCursor.CopyOf(new byte[] { 1, 2, 3, 4 }, Limits(read: 2, total: 2)))
            using (var clone = cursor.Clone().CreatedCursor)
            {
                Expect(cursor.Read(uint.MaxValue), CursorAdmission.PerReadLimit, null, 0, 0, 0,
                       "Unbounded read request admitted.");
                Expect(cursor.Read(3), CursorAdmission.PerReadLimit, null, 0, 0, 0, "Per-call cap ignored.");
                Check(cursor.Observe().PayloadAllocations == 0 && cursor.Observe().BytesRead == 0,
                      "Refused read allocated payload or consumed bytes.");
                Expect(cursor.Read(2), CursorAdmission.Admitted, 0, 2, 0, 2, "Allowed bounded read.");
                Expect(clone.Read(1), CursorAdmission.TotalReadLimit, null, 0, 0, 0,
                       "Clone reset cumulative read budget.");
                Expect(clone.Read(0), CursorAdmission.Admitted, 0, 0, 0, 0, "Zero read after byte budget exhausted.");
                cursor.Seek(0, CursorOrigin.End);
                Expect(cursor.Read(1), CursorAdmission.Admitted, 1, 0, 4, 4, "EOF needs no byte budget.");
                Check(cursor.Observe().BytesRead == 2 && cursor.Observe().PayloadAllocations == 1,
                      "Cumulative accounting changed on refusals/EOF.");
            }
            using (var cursor = SnapshotCursor.CopyOf(new byte[] { 9 }, Limits(calls: 3)))
            using (var clone = cursor.Clone().CreatedCursor)
            {
                cursor.Seek(-1, CursorOrigin.Current); // Invalid operations still consume one admitted call.
                Expect(clone.Read(0), CursorAdmission.Admitted, 0, 0, 0, 0, "Last shared call.");
                Expect(cursor.Read(0), CursorAdmission.CallLimit, null, 0, 0, 0,
                       "Original reset shared call budget or fabricated zero-read success.");
                Expect(clone.Seek(0, CursorOrigin.Set), CursorAdmission.CallLimit, null, 0, 0, 0, "Clone call cap.");
                Expect(cursor.Clone(), CursorAdmission.CallLimit, null, 0, 0, 0, "Clone creation bypassed call cap.");
                Check(cursor.Observe().Calls == 3, "Refused admission increments beyond call cap.");
            }
            var capped = SnapshotCursor.CopyOf(new byte[] { 1 }, Limits(clones: 1));
            var first = capped.Clone().CreatedCursor;
            Expect(first.Clone(), CursorAdmission.CloneLimit, null, 0, 0, 0, "Clone-of-clone bypassed shared cap.");
            first.Dispose();
            Expect(capped.Clone(), CursorAdmission.CloneLimit, null, 0, 0, 0, "Dispose reclaimed lifetime clone budget.");
            capped.Dispose();
            Check(capped.Observe().LastOwnerReleases == 1, "Cleanup unavailable after clone cap.");
            using (var zero = SnapshotCursor.CopyOf(new byte[] { 1 }, Limits(read: 0, total: 0, clones: 0)))
            {
                Expect(zero.Read(0), CursorAdmission.Admitted, 0, 0, 0, 0, "Zero read with zero byte caps.");
                Expect(zero.Read(1), CursorAdmission.PerReadLimit, null, 0, 0, 0, "Zero per-read cap.");
                Expect(zero.Clone(), CursorAdmission.CloneLimit, null, 0, 0, 0, "Zero clone cap.");
            }
        }

        public static int Run()
        {
            assertions = 0;
            Check(!SnapshotQualification.NativeEligibility && SnapshotQualification.Provider == "Unknown_Unqualified" &&
                  SnapshotQualification.DbgHelpPdbUnmatched == "NotApplicable" && SnapshotQualification.H3Outcome == "Refused" &&
                  !SnapshotQualification.RealGuardQualified && !SnapshotQualification.ProviderQuiescenceQualified &&
                  !SnapshotQualification.ChildClosureQualified, "Source tests promoted runtime qualification.");
            Throws<ArgumentOutOfRangeException>(() => new SnapshotLimits(-1, 1, 1, 1, 1), "Negative input cap.");
            Throws<ArgumentOutOfRangeException>(() => new SnapshotLimits(1, -1, 1, 1, 1), "Negative read cap.");
            Throws<ArgumentOutOfRangeException>(() => new SnapshotLimits(1, 1, 1, 0, 1), "No finite positive call budget.");
            Throws<ArgumentOutOfRangeException>(() => new SnapshotLimits(1, 1, 1, 1, -1), "Negative clone cap.");
            Throws<ArgumentOutOfRangeException>(() => SnapshotCursor.CopyOf(new byte[17], Limits()), "Oversize input accepted.");
            Throws<ArgumentNullException>(() => SnapshotCursor.CopyOf(null, Limits()), "Null input accepted.");
            Throws<ArgumentNullException>(() => SnapshotCursor.CopyOf(Array.Empty<byte>(), null), "Null limits accepted.");
            ImmutableBytesAndEof();
            SeekBoundaries();
            CloneAndRetention();
            SharedLimits();
            return assertions;
        }
    }
}
